# Bootstrap automation plan

**Status: ✅ Both phases implemented.** User-facing documentation: [Setting Up a New Machine](https://github.com/uhop/dotfiles/wiki/Setting-Up-a-New-Machine).

## Two phases

### Phase 1: SSH setup — `bootstrap-remote` ✅

Standalone script, runs from the operator's machine. Sets up passwordless SSH access to a vanilla host.

```
bootstrap-remote <host> [options]
```

**Default is dry-run.** Prints every command with explanations. Re-run with `--apply` to execute.

Steps:
1. Copy SSH public key via `ssh-copy-id` (auto-detects `id_ed25519` > `id_rsa` > `id_ecdsa`).
2. Verify key-based access works.
3. Harden `sshd_config`: disable `PasswordAuthentication`, disable `PermitRootLogin`.
4. Restart `sshd` (detects systemd vs launchd).
5. Verify access after hardening. **Rolls back from backup on failure.**

Options: `--apply`, `--skip-copy-key`, `--skip-harden`, `-k <path>`.

### Phase 2: Dotfiles installation — `bootstrap-dotfiles` ✅

Standalone script, runs from the operator's machine. Requires Phase 1 (or manual SSH setup).

```
bootstrap-dotfiles <host> [options]
```

Steps:
1. Verifies passwordless SSH access.
2. Detects remote OS (`uname`, `/etc/os-release`).
3. Generates a self-contained install script tailored to the OS:
   - **Debian/Ubuntu:** `apt install build-essential curl git...` → brew → chezmoi
   - **macOS:** Xcode CLT → brew → bash shell switch → chezmoi
   - **Other Linux:** warns and asks user to install prerequisites manually
4. Uploads the script to `/tmp/install-dotfiles.sh` on the remote host.
5. Prints instructions: "Open another terminal, `ssht <host>`, run the script."

The install script is interactive (sudo prompts, chezmoi config questions, Y/N reboot). This is by design — the user runs it in their own SSH session.

Options: `--github-user <name>` (default: uhop).

## Design decisions

- **Two standalone scripts, not a `playbash` subcommand.** Phase 1 can't use playbash (no SSH access yet). Phase 2 could, but keeping both standalone is simpler and more consistent. `bootstrap-dotfiles` uses plain `ssh` for the upload — `playbash put` isn't needed for a single file.
- **Dry-run default for `bootstrap-remote`.** SSH hardening is high-risk (lockout). Follows the project convention: wrapper utilities print commands, destructive ops default to dry-run.
- **Generated script, not a pushed script.** The install script is generated at runtime based on the detected OS. This avoids maintaining separate scripts per platform and keeps the logic in one place.

## What stays manual

- Initial SSH access with password (unavoidable for a truly vanilla host).
- Post-setup: tmux plugin install (<kbd>Prefix</kbd>+<kbd>I</kbd>), fonts, GUI tweaks.
