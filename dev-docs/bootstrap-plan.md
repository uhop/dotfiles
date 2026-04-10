# Bootstrap automation plan

How to set up a vanilla machine with this project. The SSH and hardening workflow is documented in [Workflows: remote](https://github.com/uhop/dotfiles/wiki/Workflows-remote). This document covers automation opportunities.

## Current manual flow

1. SSH into vanilla machine with password.
2. Copy public key (`ssh-copy-id`), then harden: disable password login and root login in `sshd_config`.
3. Copy-paste prerequisite commands from README.md (`sudo apt install build-essential curl git git-gui gitk micro`, brew install, chezmoi init).
4. Reboot.

## Automation opportunities

### SSH hardening (step 2)

Could be a standalone script with dry-run mode that:
- Copies the local SSH public key (`ssh-copy-id`)
- Disables `PasswordAuthentication`, `PermitRootLogin` in `sshd_config`
- Restarts `sshd`
- Verifies key-based access from a second connection before committing

Doing it wrong locks you out. A careful script is valuable but should be opt-in, not part of bootstrap.

### Prerequisites + chezmoi (step 3)

Could be a single bootstrap script that:
- Installs `build-essential`, `curl`, `git`, etc. via `apt`
- Installs brew
- Installs chezmoi and runs `chezmoi init --apply uhop`

This script must run with `sudo` access. It could be `scp`'d to the remote host and run via `ssht`. Playbash can't easily do this because the host has no tooling yet and may require interactive `sudo`.

### Proposed approach

A `bootstrap-remote` script in `~/.local/bin/` that takes a hostname and:
1. Copies itself + SSH public key to the remote host
2. Runs the prerequisites remotely
3. Does NOT harden SSH (separate concern, should be explicit)

See also `playbash bootstrap` in [playbash-roadmap.md](./playbash-roadmap.md) — a future playbash subcommand that would handle key distribution and connectivity verification.
