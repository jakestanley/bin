# bin

## Install

- `./install.sh` symlinks every executable under each top-level subdirectory (for example `./work-vpn/**`) into `/usr/local/bin` (filename becomes the command name, with a trailing `.sh` stripped).
- `./install.sh --uninstall` removes only the symlinks in `/usr/local/bin` that point back into this repo.

## work-vpn

- Create `work-vpn/.env` by copying `work-vpn/.env.example` and filling in your values.
- Run `work-vpn` after installing (or run `work-vpn/work-vpn.sh` directly).
