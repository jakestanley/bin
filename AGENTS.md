# AGENTS.md

This file defines global conventions and constraints for all scripts in this repository.

The purpose of these rules is to keep the repo predictable, safe, and maintainable.
If a script does not follow these rules, it does not belong here.

---

## Repository Structure

- All executable scripts MUST live in top-level subdirectories of the repository root (for example ./work-vpn/).
- Scripts may be grouped by purpose (for example `work-vpn/`)
- The repository root MUST contain only these files (repo metadata + installers):
  - `install.sh` (macOS installer)
  - `install.ps1` (Windows installer)
  - `AGENTS.md`
  - `README.md`
  - `.gitignore`

Top-level directories are allowed, and should generally be one directory per tool (for example `./work-vpn/`, `./homelab-sync/`).

No other executable scripts may live in the repository root (installers are the only exception).

---

## Installation Model

- macOS scripts are installed exclusively via symlinks
- Windows ports are installed via small `*.cmd` wrappers that invoke the corresponding `*.ps1`
- `install.sh` and `install.ps1` are the authoritative installers for their platforms
- Installed macOS commands live in `/usr/local/bin`
- Command names are derived from filenames
  - `foo.sh` becomes `foo`
- `install.sh --uninstall` MUST remove only symlinks that point back into this repository
- `install.ps1 -Uninstall` MUST remove only wrappers that point back into this repository

Scripts MUST NOT self-install.

---

## Script Requirements (Mandatory)

All executable scripts MUST:

- Use macOS-compatible `bash`
- Start with the following header lines:
  - `#!/usr/bin/env bash`
  - `set -euo pipefail`
- Fail fast with clear error messages
- Be safe to interrupt (Ctrl+C)
- Avoid persistent global state

---

## Configuration and Secrets

- Environment-specific and work-specific values MUST NOT be hardcoded
- Configuration MUST be externalised using:
  - `.env` (gitignored)
  - `.env.example` (committed)
- Scripts MUST:
  - Explicitly load `.env`
  - Error if required variables are missing
- Defaults and documentation belong in `.env.example`, NOT in scripts

Secrets MUST NEVER be committed.

---

## System and Network Safety

Scripts MUST leave the system in the same state they found it.

In particular:

- Global DNS modification is forbidden (do not set system-wide DNS to VPN or corporate resolvers)
- Cleanup MAY reset per-service DNS back to DHCP using `networksetup -setdnsservers <service> empty` (this is considered restorative cleanup, not configuration)
- Scoped DNS via `/etc/resolver/<domain>` is preferred for corporate domains
- Persistent SystemConfiguration changes are forbidden unless unavoidable
- Temporary system changes MUST:
  - Be scoped
  - Be reversible
  - Be cleaned up using trap-based cleanup

If a script modifies system state, it MUST implement cleanup on exit and interruption.

---

## VPN and Networking Scripts

Additional mandatory rules for VPN-related tooling:

- Prefer scoped configuration over global configuration
- DNS MUST be handled via `/etc/resolver/<domain>` where required
- Global DNS injection is forbidden
- Scripts MUST exit cleanly without requiring a reboot

If these guarantees cannot be met, the script is not acceptable.

---

## Logging and UX

- Scripts SHOULD log high-level actions
- Avoid excessive verbosity by default
- Errors SHOULD be actionable
- Interactive prompts SHOULD be avoided unless strictly required

---

## Adding New Scripts

Before adding a new script, ensure:

1. The script lives under `./<script-name>/`
2. Configuration is externalised correctly
3. All system changes are cleaned up
4. The script can be installed automatically by `install.sh`

If any answer is “no”, fix it before committing.

---

## Philosophy

This repository is for small, sharp tools that are:

- Boring
- Predictable
- Disposable
- Easy to understand months later

Cleverness is a liability.

## macOS VPN (openconnect-sso) DNS policy

Goal: Use openconnect-sso on macOS without allowing vpnc-script to modify global DNS/search domains.

Rules:
- Do not use `networksetup -setdnsservers` or any global DNS mutation.
- Use `/etc/resolver/<domain>` for split-DNS (scoped DNS) instead.
- When connecting, pass OpenConnect options after `--` so they reach `openconnect`.

Implementation:
- Install resolver files from `config/macos/resolver/` into `/etc/resolver/` via `scripts/macos/install-resolvers.sh`.
- Use a vpnc-script wrapper that strips all DNS-related env vars before delegating to the real vpnc-script.
  - Wrapper source: `scripts/vpn/vpnc-script-no-dns`
  - Installed path: `/opt/homebrew/etc/vpnc/vpnc-script-no-dns` (executable)

Connect command:
- `sudo openconnect-sso https://<WORK_VPN_ENDPOINT_URL>/ -- --script /opt/homebrew/etc/vpnc/vpnc-script-no-dns`
  - note that `WORK_VPN_ENDPOINT_URL` can have a path

Verification:
- `scutil --dns` must show scoped resolvers for corpname2.co.uk (and corpname1.co.uk if present)
- global resolver must remain unchanged.

### Resolver configuration (local-only, not committed)

Corporate DNS resolver IPs are considered sensitive and MUST NOT be committed.

Policy:
- Resolver files under /etc/resolver/<domain> are REQUIRED for split DNS.
- Actual resolver files MUST be created locally and ignored by git.
- The repository may contain examples or templates ONLY.

Allowed in repo:
- docs describing required domains
- *.example files with placeholder IPs

Forbidden:
- committing real corporate DNS IPs
- committing /etc/resolver contents verbatim

Only *.example resolver files may be committed.
All real resolver files are local-only and gitignored.
