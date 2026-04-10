# Bootstrap automation plan

How to set up a vanilla machine with this project. The user-facing documentation is in [Setting Up a New Machine](https://github.com/uhop/dotfiles/wiki/Setting-Up-a-New-Machine) on the wiki.

## Current flow

1. SSH into vanilla machine with password.
2. `ssh-copy-id user@host` — distribute public key.
3. Harden: disable password login and root login in `sshd_config`, restart `sshd`.
4. Install prerequisites, brew, chezmoi — copy-paste from README.
5. Reboot.

Steps 2-3 are documented in the wiki. Step 4 is the copy-paste bottleneck.

## What to automate

### Step 4: a `bootstrap-remote` script

A utility in `~/.local/bin/` that runs from the **operator's machine** (not the target). Takes a hostname, assumes passwordless SSH is already working.

```
bootstrap-remote <host> [options]
```

What it does:
1. Detects the remote OS (`uname`, `/etc/os-release`).
2. Installs prerequisites via ssh:
   - **Debian/Ubuntu:** `sudo apt install -y build-essential curl git git-gui gitk micro`
   - **macOS:** Xcode CLT (`xcode-select --install`) if needed
3. Installs brew remotely (`curl -fsSL ... | bash`).
4. Installs chezmoi and applies (`brew install chezmoi && chezmoi init --apply uhop`).
5. Reports success or failure.

**Design constraints:**
- Requires `sudo` on the remote host — the target still has password-based sudo at this point (no `doas` yet). The script must handle the sudo password prompt. Options: `ssh -t` for TTY forwarding (simplest), or document that the user should run `sudo -v` on the remote first.
- Should be idempotent — re-running skips already-installed components.
- A `--dry-run` flag shows what would be executed.

### Steps 2-3: SSH hardening (separate, opt-in)

A `harden-ssh` script that:
1. Verifies key-based access works (`ssh -o BatchMode=yes host true`).
2. Backs up `sshd_config`.
3. Sets `PasswordAuthentication no` and `PermitRootLogin no`.
4. Restarts `sshd`.
5. Opens a **second** connection to verify — if it fails, rolls back from the backup.

This is high-risk (lockout) so it should be a separate utility, never run automatically. The rollback-on-failure is the key safety feature.

### What stays manual

- **Step 1:** Initial SSH access with password — no way around this for a truly vanilla host.
- **Step 2 (key distribution):** `ssh-copy-id` is one command and hard to improve on. Could be folded into `bootstrap-remote` as a `--copy-key` flag.
- **Post-setup:** tmux plugin installation (<kbd>Prefix</kbd>+<kbd>I</kbd>), font installation, platform-specific tweaks — see wiki.

## Relationship to playbash

`playbash bootstrap` is a future playbash subcommand (see [playbash-roadmap.md](./playbash-roadmap.md) § Future) that would handle key distribution + connectivity verification as part of the playbash UX. It needs its own design because it's interactive — contrary to playbash's `BatchMode=yes` architecture.

`bootstrap-remote` is the simpler, standalone alternative that doesn't depend on playbash and can run before playbash exists on the target.

## Implementation order

1. Write `bootstrap-remote` — covers the common case (Debian/Ubuntu target, SSH already working).
2. Write `harden-ssh` — opt-in, with rollback safety.
3. Revisit `playbash bootstrap` after both scripts exist — it may just wrap them.
