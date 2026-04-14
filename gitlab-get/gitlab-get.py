#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
from urllib.parse import quote

import requests
import yaml


class ConfigError(Exception):
    pass


class APIError(Exception):
    pass


def load_config(path: Path) -> dict:
    if not path.exists():
        raise ConfigError(f"Missing config file: {path}\nCopy {path.parent}/.env.yaml.example to {path} and fill in your values.")
    try:
        data = yaml.safe_load(path.read_text())
    except Exception as exc:
        raise ConfigError(f"Invalid YAML in config file: {path}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"Invalid config structure in {path}")
    return data


def select_server(config: dict, server_name: str | None) -> tuple[str, str]:
    servers = config.get("servers")
    if not isinstance(servers, dict):
        raise ConfigError("Missing or invalid 'servers' block in config")

    name = server_name or config.get("default_server")
    if not name:
        raise ConfigError("No --server specified and no 'default_server' set in config")

    server = servers.get(name)
    if not server:
        available = ", ".join(servers.keys())
        raise ConfigError(f"Server '{name}' not found in config. Available: {available}")

    url = server.get("url", "").rstrip("/")
    token = server.get("token", "")
    if not url:
        raise ConfigError(f"Server '{name}' is missing 'url'")
    if not token:
        raise ConfigError(f"Server '{name}' is missing 'token'")

    return url, token


def api_get(base_url: str, token: str, path: str, params: dict | None = None) -> requests.Response:
    url = f"{base_url}/api/v4{path}"
    resp = requests.get(url, headers={"PRIVATE-TOKEN": token}, params=params or {}, timeout=30)
    return resp


def get_group_projects(base_url: str, token: str, group_path: str) -> list[dict]:
    encoded = quote(group_path, safe="")
    projects = []
    page = 1

    while True:
        resp = api_get(base_url, token, f"/groups/{encoded}/projects", {
            "include_subgroups": "true",
            "per_page": "100",
            "page": str(page),
        })
        if resp.status_code == 404:
            return None
        if not resp.ok:
            raise APIError(f"GitLab API error {resp.status_code}: {resp.text}")

        batch = resp.json()
        projects.extend(batch)

        next_page = resp.headers.get("X-Next-Page", "")
        if not next_page:
            break
        page = int(next_page)

    return projects


def get_single_project(base_url: str, token: str, project_path: str) -> dict | None:
    encoded = quote(project_path, safe="")
    resp = api_get(base_url, token, f"/projects/{encoded}")
    if resp.status_code == 404:
        return None
    if not resp.ok:
        raise APIError(f"GitLab API error {resp.status_code}: {resp.text}")
    return resp.json()


def cmd_repos(args: argparse.Namespace, base_url: str, token: str) -> int:
    path = args.path
    url_field = "ssh_url_to_repo" if args.ssh else "http_url_to_repo"

    projects = get_group_projects(base_url, token, path)

    if projects is None:
        project = get_single_project(base_url, token, path)
        if project is None:
            print(f"Not found: '{path}' is neither a group nor a project on this server", file=sys.stderr)
            return 1
        print(project[url_field])
        return 0

    if not projects:
        print(f"No projects found under '{path}'", file=sys.stderr)
        return 1

    for project in projects:
        print(project[url_field])

    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Query GitLab servers")
    parser.add_argument("--server", help="Server name from config (overrides default_server)")

    sub = parser.add_subparsers(dest="command", required=True)

    repos = sub.add_parser("repos", help="List repository URLs under a group or project path")
    repos.add_argument("path", help="GitLab group or project path (e.g. myorg or myorg/platform)")
    url_group = repos.add_mutually_exclusive_group(required=True)
    url_group.add_argument("--ssh", action="store_true", help="Output SSH clone URLs")
    url_group.add_argument("--https", action="store_true", help="Output HTTPS clone URLs")

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    config_path = Path(__file__).resolve().parent / ".env.yaml"
    try:
        config = load_config(config_path)
        base_url, token = select_server(config, args.server)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    try:
        if args.command == "repos":
            return cmd_repos(args, base_url, token)
    except APIError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
