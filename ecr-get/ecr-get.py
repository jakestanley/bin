#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError, ProfileNotFound

ECR_HOST_RE = re.compile(
    r"^(?P<registry_id>\d{12})\.dkr\.ecr\.(?P<region>[a-z0-9-]+)\.amazonaws\.com$"
)


class ConfigError(Exception):
    pass


class ImageUriError(Exception):
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


def get_profile(profile_groups: dict, group_name: str, account_type: str) -> str:
    try:
        group = profile_groups[group_name]
    except KeyError as exc:
        raise ConfigError(f"Unknown profile group: {group_name}") from exc
    try:
        return group[account_type]
    except KeyError as exc:
        raise ConfigError(f"Missing profile for {group_name}.{account_type}") from exc


def parse_image_uri(uri: str) -> dict:
    """Split a fully qualified ECR image URI into its parts."""
    value = uri.strip()
    if "://" in value:
        value = value.split("://", 1)[1]

    if "/" not in value:
        raise ImageUriError(
            f"Not a fully qualified ECR image URI: {uri}\n"
            "Expected <account>.dkr.ecr.<region>.amazonaws.com/<repository>:<tag>"
        )

    host, remainder = value.split("/", 1)
    match = ECR_HOST_RE.match(host)
    if not match:
        raise ImageUriError(
            f"Not an ECR registry host: {host}\n"
            "Expected <account>.dkr.ecr.<region>.amazonaws.com/<repository>:<tag>"
        )

    tag = None
    digest = None
    if "@" in remainder:
        repository, digest = remainder.split("@", 1)
    elif ":" in remainder.rsplit("/", 1)[-1]:
        repository, tag = remainder.rsplit(":", 1)
    else:
        raise ImageUriError(f"Image URI has no tag or digest: {uri}")

    if not repository:
        raise ImageUriError(f"Image URI has no repository: {uri}")
    if tag == "" or digest == "":
        raise ImageUriError(f"Image URI has an empty tag or digest: {uri}")

    return {
        "registry_id": match.group("registry_id"),
        "region": match.group("region"),
        "repository": repository,
        "tag": tag,
        "digest": digest,
    }


def check_against_config(image: dict, ecr_cfg: dict) -> None:
    configured_repo = ecr_cfg.get("repository")
    if configured_repo and image["repository"] != configured_repo:
        raise ConfigError(
            f"Image repository '{image['repository']}' does not match the configured "
            f"repository '{configured_repo}'"
        )

    configured_registry = ecr_cfg.get("registry_id")
    if configured_registry and image["registry_id"] != str(configured_registry):
        raise ConfigError(
            f"Image registry '{image['registry_id']}' does not match the configured "
            f"registry '{configured_registry}'"
        )


def format_size(size_bytes: int | None) -> str:
    if not size_bytes:
        return "unknown"
    mib = size_bytes / (1024 * 1024)
    return f"{mib:.1f} MiB"


def auth_error(profile: str, exc: Exception) -> None:
    msg = (
        f"AWS authentication failed for profile '{profile}'. "
        f"Run: aws sso login --profile {profile}"
    )
    print(msg, file=sys.stderr)
    raise SystemExit(3) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check whether a fully qualified ECR image URI exists in the configured repository."
    )
    parser.add_argument(
        "image",
        help="Fully qualified image URI, for example "
        "000000000000.dkr.ecr.eu-west-2.amazonaws.com/my-repo:1.2.3",
    )
    parser.add_argument("--profile", dest="profile", help="AWS profile (overrides config)")
    parser.add_argument("--region", dest="region", help="AWS region (overrides the image URI)")
    parser.add_argument(
        "--quiet",
        dest="quiet",
        action="store_true",
        help="Print nothing; report the result via exit code only",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    config_path = Path(__file__).resolve().parent / "ecr-get.yaml"
    try:
        config = load_config(config_path)
        image = parse_image_uri(args.image)
    except (ConfigError, ImageUriError) as exc:
        print(str(exc), file=sys.stderr)
        return 2

    ecr_cfg = config.get("ecr")
    if not isinstance(ecr_cfg, dict):
        print("Missing ecr block in config", file=sys.stderr)
        return 2

    try:
        check_against_config(image, ecr_cfg)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    profile = args.profile or ecr_cfg.get("profile")
    if not profile:
        # Fall back to the shared aws.profile_groups shape used by the other AWS tools
        aws_cfg = config.get("aws", {})
        profile_groups = aws_cfg.get("profile_groups")
        group_name = ecr_cfg.get("group")
        if not isinstance(profile_groups, dict) or not group_name:
            print("Missing ecr.profile (or ecr.group + aws.profile_groups) in config", file=sys.stderr)
            return 2
        try:
            profile = get_profile(profile_groups, group_name, ecr_cfg.get("account_type", "nonprod"))
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            return 2

    region = args.region or image["region"]

    try:
        session = boto3.Session(profile_name=profile, region_name=region)
        client = session.client("ecr")
    except (ProfileNotFound, BotoCoreError) as exc:
        auth_error(profile, exc)

    image_id = {"imageTag": image["tag"]} if image["tag"] else {"imageDigest": image["digest"]}

    try:
        response = client.describe_images(
            registryId=image["registry_id"],
            repositoryName=image["repository"],
            imageIds=[image_id],
        )
    except client.exceptions.ImageNotFoundException:
        if not args.quiet:
            print(f"does not exist: {args.image}", file=sys.stderr)
        return 1
    except client.exceptions.RepositoryNotFoundException:
        print(
            f"Repository '{image['repository']}' not found in registry "
            f"{image['registry_id']} ({region})",
            file=sys.stderr,
        )
        return 2
    except (NoCredentialsError, ClientError, BotoCoreError) as exc:
        auth_error(profile, exc)

    details = response.get("imageDetails", [])
    if not details:
        if not args.quiet:
            print(f"does not exist: {args.image}", file=sys.stderr)
        return 1

    if args.quiet:
        return 0

    detail = details[0]
    tags = detail.get("imageTags", [])
    pushed_at = detail.get("imagePushedAt")

    print(f"exists: {args.image}")
    print(f"  digest: {detail.get('imageDigest', 'unknown')}")
    print(f"  pushed: {pushed_at.isoformat() if pushed_at else 'unknown'}")
    print(f"  size:   {format_size(detail.get('imageSizeInBytes'))}")
    print(f"  tags:   {', '.join(tags) if tags else 'none'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
