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


def parse_image_uri(uri: str) -> dict:
    """Split an image reference into its parts.

    Accepts a fully qualified ECR URI, or <repository>:<tag> when the registry
    and region come from config.
    """
    value = uri.strip()
    if "://" in value:
        value = value.split("://", 1)[1]

    registry_id = None
    region = None

    head, _, rest = value.partition("/")
    match = ECR_HOST_RE.match(head)
    if match:
        registry_id = match.group("registry_id")
        region = match.group("region")
        remainder = rest
    elif "." in head and "/" in value:
        raise ImageUriError(
            f"Not an ECR registry host: {head}\n"
            "Expected <account>.dkr.ecr.<region>.amazonaws.com/<repository>:<tag>"
        )
    else:
        remainder = value

    tag = None
    digest = None
    if "@" in remainder:
        repository, digest = remainder.split("@", 1)
    elif ":" in remainder.rsplit("/", 1)[-1]:
        repository, tag = remainder.rsplit(":", 1)
    else:
        raise ImageUriError(f"Image reference has no tag or digest: {uri}")

    if not repository:
        raise ImageUriError(f"Image reference has no repository: {uri}")
    if not tag and not digest:
        raise ImageUriError(f"Image reference has an empty tag or digest: {uri}")

    return {
        "registry_id": registry_id,
        "region": region,
        "repository": repository,
        "tag": tag,
        "digest": digest,
    }


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
        description="Check whether an ECR image tag exists."
    )
    parser.add_argument(
        "image",
        help="Image reference, for example "
        "000000000000.dkr.ecr.eu-west-1.amazonaws.com/my-group/my-app:1.2.3 "
        "(or my-group/my-app:1.2.3 to use the configured registry)",
    )
    parser.add_argument("--profile", dest="profile", help="AWS profile (overrides config)")
    parser.add_argument("--region", dest="region", help="AWS region (overrides the image URI and config)")
    parser.add_argument(
        "--registry-id",
        dest="registry_id",
        help="AWS account ID of the registry (overrides the image URI and config)",
    )
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

    aws_cfg = config.get("aws", {})
    if not isinstance(aws_cfg, dict):
        print("Invalid aws block in config", file=sys.stderr)
        return 2
    ecr_cfg = config.get("ecr", {})
    if not isinstance(ecr_cfg, dict):
        print("Invalid ecr block in config", file=sys.stderr)
        return 2

    profile = args.profile or aws_cfg.get("profile")
    if not profile:
        print("Missing aws.profile in config", file=sys.stderr)
        return 2

    # The image URI wins where it carries the value; config fills the gaps
    region = args.region or image["region"] or aws_cfg.get("region")
    if not region:
        print("Missing aws.region in config and no region in the image URI", file=sys.stderr)
        return 2

    registry_id = args.registry_id or image["registry_id"] or ecr_cfg.get("registry_id")
    if not registry_id:
        print("Missing ecr.registry_id in config and no registry in the image URI", file=sys.stderr)
        return 2

    try:
        session = boto3.Session(profile_name=profile, region_name=region)
        client = session.client("ecr")
    except (ProfileNotFound, BotoCoreError) as exc:
        auth_error(profile, exc)

    image_id = {"imageTag": image["tag"]} if image["tag"] else {"imageDigest": image["digest"]}

    try:
        response = client.describe_images(
            registryId=str(registry_id),
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
            f"{registry_id} ({region})",
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
