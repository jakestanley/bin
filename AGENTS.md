# AGENTS.md

This file defines global conventions and constraints for all scripts in this repository.

The purpose of these rules is to keep the repo predictable, safe, and maintainable.
If a script does not follow these rules, it does not belong here.

---

## Repository Structure

- All executable scripts MUST live in top-level subdirectories of the repository root (for example ./work-vpn/).
- Scripts may be grouped by purpose (for example `work-vpn/`)
- The repository root MUST contain only:
  - `install.sh`
  - `AGENTS.md`
  - `README.md`

No executable scripts may live in the repository root.

---

## Installation Model

- Scripts are installed exclusively via symlinks
- `install.sh` is the single authoritative installer
- Installed commands live in `/usr/local/bin`
- Command names are derived from filenames
  - `foo.sh` becomes `foo`
- `install.sh --uninstall` MUST remove only symlinks that point back into this repository

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
