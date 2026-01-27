# homelab-sync

Keeps core homelab repositories in sync on a machine by:

1. Verifying repos are clean (no uncommitted changes).
2. `git fetch`, `git pull --ff-only`, `git push`.
3. Running `scripts/sync_imports.py` in each repo (preferring a local venv if present).

## Setup

- Copy `homelab-sync/.env.example` to `homelab-sync/.env` and fill it in.
- Install on macOS: `./install.sh`

## Usage (macOS)

- `homelab-sync`
- Dry run: `homelab-sync --dry-run`

## Usage (Windows)

- Run directly: `powershell -NoProfile -ExecutionPolicy Bypass -File homelab-sync\\homelab-sync.ps1`
- Dry run: `powershell -NoProfile -ExecutionPolicy Bypass -File homelab-sync\\homelab-sync.ps1 -DryRun`

## Notes

- `git pull --ff-only` intentionally fails on divergence; resolve manually (rebase/merge) and rerun.
- If you want a different Python on Windows/macOS, set `HOMELAB_SYNC_PYTHON` in `homelab-sync/.env`.
