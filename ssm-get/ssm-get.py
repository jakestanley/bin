#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError, ProfileNotFound
from tabulate import tabulate

VALID_ENVS = ["dev", "sit", "preprod", "prod"]
NONPROD_ENVS = {"dev", "sit", "preprod"}
REDACTED = "REDACTED"


class ConfigError(Exception):
    pass


def load_config(path: Path) -> dict:
    if not path.exists():
        raise ConfigError(f"Missing config file: {path}")
    try:
        data = yaml.safe_load(path.read_text())
    except Exception as exc:
        raise ConfigError(f"Invalid YAML in config file: {path}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"Invalid config structure in {path}")
    return data


def select_envs(service_cfg: dict, cli_env: str | None) -> list[str]:
    if cli_env:
        if cli_env not in VALID_ENVS:
            raise ConfigError(f"Invalid environment: {cli_env}")
        return [cli_env]

    allowed = service_cfg.get("envs")
    if allowed:
        return [env for env in VALID_ENVS if env in allowed]
    return list(VALID_ENVS)


def get_profile(profile_groups: dict, group_name: str, account_type: str) -> str:
    try:
        group = profile_groups[group_name]
    except KeyError as exc:
        raise ConfigError(f"Unknown profile group: {group_name}") from exc
    try:
        return group[account_type]
    except KeyError as exc:
        raise ConfigError(f"Missing profile for {group_name}.{account_type}") from exc


def get_prefixes(service_name: str, service_cfg: dict) -> list[str]:
    prefixes = service_cfg.get("match_path_prefixes")
    if prefixes:
        return list(prefixes)
    return [f"/{service_name}-"]


def fetch_parameters(client, base_path: str, with_decryption: bool) -> list[dict]:
    resp = client.get_parameters_by_path(
        Path=base_path,
        Recursive=True,
        WithDecryption=with_decryption,
    )
    return resp.get("Parameters", [])


def build_env_data(parameters: list[dict], base_path: str, with_decryption: bool) -> dict:
    data: dict[str, str] = {}
    prefix = base_path.rstrip("/") + "/"
    for param in parameters:
        name = param.get("Name", "")
        key = name[len(prefix) :] if name.startswith(prefix) else name
        value = param.get("Value", "")
        if param.get("Type") == "SecureString" and not with_decryption:
            value = REDACTED
        data[key] = value
    return data


def auth_error(profile: str, exc: Exception) -> None:
    msg = (
        f"AWS authentication failed for profile '{profile}'. "
        f"Run: aws sso login --profile {profile}"
    )
    print(msg, file=sys.stderr)
    raise SystemExit(3) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare SSM parameters across environments.")
    parser.add_argument("service", help="Service name from config")
    parser.add_argument("--env", dest="env", help="Environment to query")
    parser.add_argument(
        "--with-decryption",
        dest="with_decryption",
        action="store_true",
        help="Enable decryption of SecureString parameters",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    config_path = Path(__file__).resolve().parent / "ssm-get.yaml"
    try:
        config = load_config(config_path)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    services = config.get("services")
    if not isinstance(services, dict) or args.service not in services:
        print(f"Unknown service: {args.service}", file=sys.stderr)
        return 2

    service_cfg = services[args.service]
    group_name = service_cfg.get("group")
    if not group_name:
        print(f"Service '{args.service}' is missing 'group'", file=sys.stderr)
        return 2

    aws_cfg = config.get("aws", {})
    profile_groups = aws_cfg.get("profile_groups")
    if not isinstance(profile_groups, dict):
        print("Missing aws.profile_groups in config", file=sys.stderr)
        return 2

    try:
        envs = select_envs(service_cfg, args.env)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    data: dict[str, dict[str, str]] = {env: {} for env in envs}
    prefixes = get_prefixes(args.service, service_cfg)

    for env in envs:
        account_type = "prod" if env == "prod" else "nonprod"
        try:
            profile = get_profile(profile_groups, group_name, account_type)
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            return 2

        try:
            session = boto3.Session(profile_name=profile)
            client = session.client("ssm")
        except (ProfileNotFound, BotoCoreError) as exc:
            auth_error(profile, exc)

        env_data: dict[str, str] = {}
        env_candidates = [env]
        if env == "preprod":
            env_candidates.append("pre")

        found = False
        for prefix in prefixes:
            for env_candidate in env_candidates:
                base_path = f"{prefix}{env_candidate}"
                try:
                    params = fetch_parameters(client, base_path, args.with_decryption)
                except (NoCredentialsError, BotoCoreError, ClientError) as exc:
                    auth_error(profile, exc)

                if params:
                    env_data = build_env_data(params, base_path, args.with_decryption)
                    found = True
                    break
            if found:
                break

        data[env] = env_data

    all_keys: set[str] = set()
    for env in envs:
        all_keys.update(data[env].keys())

    headers = ["key"] + envs
    rows = []
    for key in sorted(all_keys):
        row = [key]
        for env in envs:
            row.append(data[env].get(key, ""))
        rows.append(row)

    print(tabulate(rows, headers=headers, tablefmt="github"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
