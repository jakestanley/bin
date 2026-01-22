# bin

## Install

- `./install.sh` symlinks every executable under `./bin/**` into `/usr/local/bin` (filename becomes the command name, with a trailing `.sh` stripped).
- `./install.sh --uninstall` removes only the symlinks in `/usr/local/bin` that point back into this repo.

## work-vpn

- Create `bin/work-vpn/.env` by copying `bin/work-vpn/.env.example` and filling in your values.
- Run `work-vpn` after installing (or run `bin/work-vpn/work-vpn.sh` directly).
