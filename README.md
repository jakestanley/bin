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

## Windows install

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\\install.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\\install.ps1 -Uninstall`
