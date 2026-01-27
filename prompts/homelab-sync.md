I want to create a new script "homelab-sync". This will ensure that core homelab infrastructure is in sync on each machine.

This will perform actions on three repos in the current folder:
- homelab-infra (required)
- homelab-edge (optional)
- homelab-standards (required

Actions:
- Check the repositories have no uncommitted changes (error if so)
- Pull and push to ensure the repositories latest changes are pushed to origin (error on conflict/issues)
- run ./scripts/sync_imports.py in each folder (activating the venv temporarily if one is present)

Deliverables:
- a script that will synchronise core homelab repositories and imports (focused deliverable)
- a port to powershell for running it on Windows
- install.ps1 that will install any windows ports to a location on the Windows path, analogous to install.sh
- documentation to support
- adhere to AGENTS.md and existing standards
