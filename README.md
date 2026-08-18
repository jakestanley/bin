# bin

## Install

- `./install.sh` symlinks every executable under each top-level subdirectory (for example `./work-vpn/**`) into `/usr/local/bin` (filename becomes the command name, with a trailing `.sh` stripped).
- `./install.sh --uninstall` removes only the symlinks in `/usr/local/bin` that point back into this repo.

## work-vpn

- Create `work-vpn/.env` by copying `work-vpn/.env.example` and filling in your values.
- Run `work-vpn` after installing (or run `work-vpn/work-vpn.sh` directly).

## homelab-sync

- Create `homelab-sync/.env` by copying `homelab-sync/.env.example` and filling in your values.
- Run `homelab-sync` after installing (or run `homelab-sync/homelab-sync.sh` directly).

## ssm-get

- Create `ssm-get/ssm-get.yaml` by copying `ssm-get/ssm-get.yaml.example` and filling in your values.
- Run `ssm-get SERVICE_NAME [--env dev|sit|preprod|prod] [--with-decryption]`.
- Use `--html` to write an HTML table to `ssm-get/temp.html` and open it in the default browser (use `--no-open` to skip auto-opening).

## cloudwatch-get

- Create `cloudwatch-get/cloudwatch-get.yaml` by copying `cloudwatch-get/cloudwatch-get.yaml.example` and filling in your values.
- Run `cloudwatch-get BASE_NAME --env ENV [--from YYYY-MM-DD|YYYY-MM-DDTHH:MM:SS] [--to YYYY-MM-DD|YYYY-MM-DDTHH:MM:SS] [--out-dir DIR] [--profile PROFILE] [--region REGION]`.
- Log group resolution matches names that end with `<base>-<env>` (for example `my-cool-api-prod` or `some-prefix-my-cool-api-prod`).

## taskdef-get

- Create `taskdef-get/taskdef-get.yaml` by copying `taskdef-get/taskdef-get.yaml.example` and filling in your values.
- Run `taskdef-get SERVICE_NAME [--env dev|sit|preprod|prod] [--cluster CLUSTER_NAME]`.
- Outputs the active task definition JSON for the matched ECS service.

## ecr-get

- Create `ecr-get/ecr-get.yaml` by copying `ecr-get/ecr-get.yaml.example` and filling in your values.
- Run `ecr-get IMAGE [--profile PROFILE] [--region REGION] [--registry-id ID] [--quiet]`, where `IMAGE` is any fully qualified ECR URI (for example `000000000000.dkr.ecr.eu-west-1.amazonaws.com/my-group/my-app:1.2.3`). A digest (`@sha256:...`) works in place of a tag.
- `REPOSITORY:TAG` on its own also works; the registry and region then come from config.
- Reports whether the image exists. Exit codes: `0` exists, `1` does not exist, `2` config or input error, `3` AWS auth failure.


## alias-here

- Run `alias-here NAME` to append `alias NAME="cd <absolute-current-directory>"` to `~/.zsh_aliases`.
- The command errors if an alias with the same name already exists.

## Windows install

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\\install.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\\install.ps1 -Uninstall`
