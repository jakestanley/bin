#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError, ProfileNotFound

INPUT_DATE_FORMAT = "%Y-%m-%d"
INPUT_DATETIME_FORMAT = "%Y-%m-%dT%H:%M:%S"
OUTPUT_TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S"
OUTPUT_WINDOW_FORMAT = "%Y%m%dT%H%M%S"
DEFAULT_WINDOW_HOURS = 12
CONFIG_RELATIVE_CANDIDATES = [
    Path("cloudwatch-get.yaml"),
    Path("../ssm-get/ssm-get.yaml"),
]


class ConfigError(Exception):
    pass


def load_config(path: Path) -> dict:
    if not path.exists():
        raise ConfigError(f"Missing config file: {path}")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ConfigError(f"Invalid YAML in config file: {path}") from exc
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ConfigError(f"Invalid config structure in {path}")
    return data


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch CloudWatch log events for a resolved log group into plain text files."
    )
    parser.add_argument("base_log_group_name", help="Base log group name (for example: my-cool-api)")
    parser.add_argument("--env", dest="env", required=True, help="Environment name (for example: sit, pre, prod)")
    parser.add_argument("--from", dest="from_ts", help="Window start: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS")
    parser.add_argument("--to", dest="to_ts", help="Window end: YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS")
    parser.add_argument("--out-dir", dest="out_dir", default=".", help="Output directory (default: current directory)")
    parser.add_argument("--profile", dest="profile", help="AWS profile override")
    parser.add_argument("--region", dest="region", help="AWS region override")
    return parser.parse_args()


def parse_local_datetime(raw_value: str) -> datetime:
    value = raw_value.strip()
    if not value:
        raise ConfigError("Datetime value cannot be empty")
    for fmt in (INPUT_DATETIME_FORMAT, INPUT_DATE_FORMAT):
        try:
            parsed = datetime.strptime(value, fmt)
            if fmt == INPUT_DATE_FORMAT:
                parsed = parsed.replace(hour=0, minute=0, second=0)
            return parsed
        except ValueError:
            continue
    raise ConfigError(
        f"Invalid datetime: {raw_value!r}. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS"
    )


def resolve_window(from_raw: str | None, to_raw: str | None) -> tuple[datetime, datetime]:
    from_dt = parse_local_datetime(from_raw) if from_raw else None
    to_dt = parse_local_datetime(to_raw) if to_raw else None
    now_local = datetime.now().replace(microsecond=0)

    if from_dt is None and to_dt is None:
        to_dt = now_local
        from_dt = to_dt - timedelta(hours=DEFAULT_WINDOW_HOURS)
    elif from_dt is not None and to_dt is None:
        to_dt = now_local
    elif from_dt is None and to_dt is not None:
        from_dt = to_dt - timedelta(hours=DEFAULT_WINDOW_HOURS)

    if from_dt is None or to_dt is None:
        raise ConfigError("Unable to resolve time window")
    if from_dt > to_dt:
        raise ConfigError("--from must be earlier than or equal to --to")
    return from_dt, to_dt


def local_datetime_to_epoch_ms(dt: datetime, *, end_of_second: bool = False) -> int:
    epoch_ms = int(time.mktime(dt.timetuple()) * 1000)
    if end_of_second:
        epoch_ms += 999
    return epoch_ms


def infer_profile_group(base_name: str) -> str:
    lowered = base_name.lower()
    if "api" in lowered:
        return "apis"
    if "service" in lowered:
        return "services"
    raise ConfigError(
        "Unable to infer profile group from base name. Include 'api' or 'service', or pass --profile."
    )


def get_profile_from_config(config: dict, group_name: str, env_name: str) -> str:
    aws_cfg = config.get("aws")
    if not isinstance(aws_cfg, dict):
        raise ConfigError("Missing aws block in config")
    profile_groups = aws_cfg.get("profile_groups")
    if not isinstance(profile_groups, dict):
        raise ConfigError("Missing aws.profile_groups in config")
    group_cfg = profile_groups.get(group_name)
    if not isinstance(group_cfg, dict):
        raise ConfigError(f"Unknown profile group: {group_name}")

    account_type = "prod" if env_name == "prod" else "nonprod"
    profile = group_cfg.get(account_type)
    if not isinstance(profile, str) or not profile.strip():
        raise ConfigError(f"Missing profile for {group_name}.{account_type}")
    return profile.strip()


def resolve_region(config: dict, group_name: str | None, override: str | None) -> str:
    if override and override.strip():
        return override.strip()

    aws_cfg = config.get("aws")
    if not isinstance(aws_cfg, dict):
        raise ConfigError("Missing aws block in config; pass --region or provide config")

    regions = aws_cfg.get("regions")
    if group_name and isinstance(regions, dict):
        group_region = regions.get(group_name)
        if isinstance(group_region, str) and group_region.strip():
            return group_region.strip()

    for key in ("default_region", "region"):
        region = aws_cfg.get(key)
        if isinstance(region, str) and region.strip():
            return region.strip()

    raise ConfigError("AWS region is not configured; pass --region or set aws.default_region in config")


def resolve_config(script_dir: Path) -> tuple[dict, Path | None]:
    for relative in CONFIG_RELATIVE_CANDIDATES:
        candidate = (script_dir / relative).resolve()
        if candidate.exists():
            return load_config(candidate), candidate
    return {}, None


def auth_error(profile: str, exc: Exception) -> None:
    msg = (
        f"AWS authentication failed for profile '{profile}'. "
        f"Run: aws sso login --profile {profile}"
    )
    print(msg, file=sys.stderr)
    raise SystemExit(3) from exc


def resolve_log_group_name(client, base_name: str, env_name: str) -> str:
    suffix = f"{base_name}-{env_name}"
    matches: list[str] = []
    paginator = client.get_paginator("describe_log_groups")
    for page in paginator.paginate():
        for group in page.get("logGroups", []):
            name = group.get("logGroupName")
            if isinstance(name, str) and name.endswith(suffix):
                matches.append(name)

    if not matches:
        raise ConfigError(f"No log groups found ending with '{suffix}'. Hint: check the base name and --env.")
    if len(matches) > 1:
        candidates = "\n".join(f"- {name}" for name in sorted(matches))
        raise ConfigError(
            f"Multiple log groups match suffix '{suffix}'. Please narrow the base name.\n{candidates}"
        )
    return matches[0]


def sanitize_filename_component(value: str) -> str:
    sanitized = re.sub(r"[\/\\:\s]+", "_", value)
    sanitized = re.sub(r"[^A-Za-z0-9._-]", "", sanitized)
    sanitized = re.sub(r"_+", "_", sanitized)
    sanitized = sanitized.strip("_")
    return sanitized or "item"


def make_utf8_safe_line(message: object) -> str:
    if isinstance(message, str):
        text = message
    elif message is None:
        text = ""
    else:
        text = str(message)
    text = text.encode("utf-8", errors="replace").decode("utf-8")
    text = text.replace("\r", "\\r").replace("\n", "\\n")
    return text


def to_output_timestamp(epoch_ms: int) -> str:
    return datetime.fromtimestamp(epoch_ms / 1000).strftime(OUTPUT_TIMESTAMP_FORMAT)


def fetch_events_by_stream(client, log_group_name: str, start_ms: int, end_ms: int) -> dict[str, list[tuple[int, int, str, str]]]:
    events_by_stream: dict[str, list[tuple[int, int, str, str]]] = {}
    seen_event_ids: set[str] = set()
    paginator = client.get_paginator("filter_log_events")

    for page in paginator.paginate(
        logGroupName=log_group_name,
        startTime=start_ms,
        endTime=end_ms,
        interleaved=True,
    ):
        for event in page.get("events", []):
            stream_name = event.get("logStreamName")
            if not isinstance(stream_name, str) or not stream_name:
                stream_name = "unknown_stream"
            event_id = event.get("eventId")
            if isinstance(event_id, str) and event_id:
                if event_id in seen_event_ids:
                    continue
                seen_event_ids.add(event_id)
            timestamp = int(event.get("timestamp") or 0)
            ingestion_time = int(event.get("ingestionTime") or 0)
            message = make_utf8_safe_line(event.get("message", ""))
            events_by_stream.setdefault(stream_name, []).append(
                (timestamp, ingestion_time, str(event_id or ""), message)
            )
    return events_by_stream


def unique_output_path(
    out_dir: Path, stem: str, used_stems: set[str]
) -> Path:
    candidate = stem
    index = 2
    while candidate in used_stems:
        candidate = f"{stem}_{index}"
        index += 1
    used_stems.add(candidate)
    return out_dir / f"{candidate}.txt"


def write_event_files(
    out_dir: Path,
    log_group_name: str,
    from_dt: datetime,
    to_dt: datetime,
    events_by_stream: dict[str, list[tuple[int, int, str, str]]],
) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    safe_group = sanitize_filename_component(log_group_name)
    from_part = from_dt.strftime(OUTPUT_WINDOW_FORMAT)
    to_part = to_dt.strftime(OUTPUT_WINDOW_FORMAT)
    used_stems: set[str] = set()
    written_paths: list[Path] = []

    for stream_name in sorted(events_by_stream):
        safe_stream = sanitize_filename_component(stream_name)
        stem = f"{safe_group}_{from_part}-{to_part}_{safe_stream}"
        path = unique_output_path(out_dir, stem, used_stems)
        events = sorted(events_by_stream[stream_name], key=lambda item: (item[0], item[1], item[2]))
        with path.open("w", encoding="utf-8", errors="replace", newline="\n") as handle:
            for timestamp, _, _, message in events:
                handle.write(f"{to_output_timestamp(timestamp)} : {message}\n")
        written_paths.append(path)

    return written_paths


def main() -> int:
    args = parse_args()
    base_name = args.base_log_group_name.strip()
    env_name = args.env.strip() if args.env else ""

    if not base_name:
        print("Base log group name cannot be empty", file=sys.stderr)
        return 2
    if not env_name:
        print("--env is required and cannot be empty", file=sys.stderr)
        return 2

    try:
        from_dt, to_dt = resolve_window(args.from_ts, args.to_ts)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    script_dir = Path(__file__).resolve().parent
    try:
        config, config_path = resolve_config(script_dir)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    inferred_group: str | None = None
    try:
        if args.profile and args.profile.strip():
            profile = args.profile.strip()
        else:
            inferred_group = infer_profile_group(base_name)
            profile = get_profile_from_config(config, inferred_group, env_name)
        region = resolve_region(config, inferred_group, args.region)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        if config_path is None:
            print(
                "No config found. Create cloudwatch-get/cloudwatch-get.yaml or ssm-get/ssm-get.yaml.",
                file=sys.stderr,
            )
        return 2

    try:
        session = boto3.Session(profile_name=profile, region_name=region)
        client = session.client("logs")
    except (ProfileNotFound, BotoCoreError) as exc:
        auth_error(profile, exc)

    start_ms = local_datetime_to_epoch_ms(from_dt)
    end_ms = local_datetime_to_epoch_ms(to_dt, end_of_second=True)
    output_dir = Path(args.out_dir).expanduser().resolve()

    try:
        resolved_log_group = resolve_log_group_name(client, base_name, env_name)
        events_by_stream = fetch_events_by_stream(client, resolved_log_group, start_ms, end_ms)
    except (NoCredentialsError, ProfileNotFound, BotoCoreError, ClientError) as exc:
        auth_error(profile, exc)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    print(f"resolved log group: {resolved_log_group}", file=sys.stderr)
    print(
        f"time window: {from_dt.strftime(OUTPUT_TIMESTAMP_FORMAT)} -> {to_dt.strftime(OUTPUT_TIMESTAMP_FORMAT)}",
        file=sys.stderr,
    )
    print(f"number of streams: {len(events_by_stream)}", file=sys.stderr)
    print(f"output directory: {output_dir}", file=sys.stderr)

    try:
        write_event_files(output_dir, resolved_log_group, from_dt, to_dt, events_by_stream)
    except OSError as exc:
        print(f"Failed writing output files: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
