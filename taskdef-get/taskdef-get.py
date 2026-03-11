#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

import boto3
import yaml
from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError, ProfileNotFound

VALID_ENVS = ["dev", "sit", "preprod", "prod"]


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


def get_service_patterns(service_name: str, service_cfg: dict) -> list[str]:
    patterns = service_cfg.get("match_service_patterns")
    if patterns:
        return list(patterns)
    return [f"{service_name}-"]


def find_ecs_service(client, cluster: str, patterns: list[str], env: str) -> str | None:
    paginator = client.get_paginator("list_services")
    env_candidates = [env, "pre"] if env == "preprod" else [env]
    
    for page in paginator.paginate(cluster=cluster):
        for arn in page.get("serviceArns", []):
            name = arn.split("/")[-1]
            for pattern in patterns:
                for env_candidate in env_candidates:
                    if name.endswith(f"{pattern}{env_candidate}"):
                        return name
    return None


def get_task_definition(client, cluster: str, service_name: str) -> dict | None:
    try:
        resp = client.describe_services(cluster=cluster, services=[service_name])
        services = resp.get("services", [])
        if not services:
            return None
        
        task_def_arn = services[0].get("taskDefinition")
        if not task_def_arn:
            return None
        
        resp = client.describe_task_definition(taskDefinition=task_def_arn)
        return resp.get("taskDefinition")
    except (ClientError, BotoCoreError):
        return None


def auth_error(profile: str, exc: Exception) -> None:
    msg = (
        f"AWS authentication failed for profile '{profile}'. "
        f"Run: aws sso login --profile {profile}"
    )
    print(msg, file=sys.stderr)
    raise SystemExit(3) from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Get active ECS task definitions for services.")
    parser.add_argument("service", help="Service name from config")
    parser.add_argument("--env", dest="env", help="Environment to query")
    parser.add_argument(
        "--cluster",
        dest="cluster",
        help="ECS cluster name (overrides config)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    config_path = Path(__file__).resolve().parent / "taskdef-get.yaml"
    try:
        config = load_config(config_path)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    services = config.get("services")
    if not isinstance(services, dict):
        print("Missing services block in config", file=sys.stderr)
        return 2

    service_cfg = services.get(args.service)
    inferred = False
    if service_cfg is None:
        inferred = True
        inferred_group = "apis" if "api" in args.service else "services"
        service_cfg = {"group": inferred_group}

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

    patterns = get_service_patterns(args.service, service_cfg)
    if inferred:
        inferred_patterns = ", ".join(patterns)
        print(
            f"Warning: '{args.service}' not found in config; inferring group='{group_name}' "
            f"and patterns=[{inferred_patterns}]",
            file=sys.stderr,
        )

    for env in envs:
        account_type = "prod" if env == "prod" else "nonprod"
        try:
            profile = get_profile(profile_groups, group_name, account_type)
        except ConfigError as exc:
            print(str(exc), file=sys.stderr)
            return 2

        try:
            session = boto3.Session(profile_name=profile)
            client = session.client("ecs")
        except (ProfileNotFound, BotoCoreError) as exc:
            auth_error(profile, exc)

        cluster = args.cluster or service_cfg.get("cluster", "default")
        
        try:
            service_name = find_ecs_service(client, cluster, patterns, env)
        except (NoCredentialsError, BotoCoreError, ClientError) as exc:
            auth_error(profile, exc)

        if not service_name:
            print(f"\n{env}: No service found", file=sys.stderr)
            continue

        task_def = get_task_definition(client, cluster, service_name)
        if not task_def:
            print(f"\n{env}: Service '{service_name}' has no task definition", file=sys.stderr)
            continue

        print(f"\n{env}: {service_name}")
        print(f"Task Definition: {task_def.get('family')}:{task_def.get('revision')}")
        print(json.dumps(task_def, indent=2, default=str))

    return 0f-8")
        if not args.no_open:
            try:
                webbrowser.open(html_path.as_uri())
            except Exception:
                pass
        print(f"Wrote HTML output to {html_path}")
    else:
        for env in envs:
            resolved = resolved_paths.get(env, "none")
            print(f"{env}: {resolved}")
        print(tabulate(rows, headers=headers, tablefmt="github"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
