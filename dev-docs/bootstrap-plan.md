# Bootstrap automation plan

How to set up a vanilla machine with this project. User-facing documentation: [Setting Up a New Machine](https://github.com/uhop/dotfiles/wiki/Setting-Up-a-New-Machine).

## Two phases

### Phase 1: SSH setup (`bootstrap-remote`)

A standalone script that runs from the **operator's machine**. Handles everything needed before playbash can reach the host.

```
bootstrap-remote <host> [options]
```

Steps:
1. Copy SSH public key to the remote host (`ssh-copy-id`). Requires password access — this is the last time a password is needed.
2. Verify key-based access works (`ssh -o BatchMode=yes host true`).
3. Harden `sshd_config`: set `PasswordAuthentication no`, `PermitRootLogin no`.
4. Restart `sshd`.
5. Open a **second** connection to verify key access still works. If it fails, roll back `sshd_config` from the backup and report the error.

**Safety:** The rollback-on-failure in step 5 is the key safety feature. Without it, a misconfigured `sshd_config` locks you out.

**Default mode is dry-run.** The script prints every command it would execute (with explanations for `sudo`-prefixed commands) and exits. The user reviews, then re-runs with `--apply` to execute for real. Even in apply mode, each command is printed before it runs (via `echoRun`).

**Options:**
- `--apply` — actually execute the commands (without this flag, dry-run is the default).
- `--skip-harden` — only copy the key, don't touch `sshd_config`. Useful when hardening was already done or needs to be done manually.
- `--skip-copy-key` — only harden, don't copy the key. Useful when key access is already set up.

After this phase, the host is reachable via passwordless SSH and `playbash exec` works.

### Phase 2: dotfiles installation (`playbash bootstrap`)

A playbash subcommand that installs the dotfiles on a host that already has SSH access.

```
playbash bootstrap <host>
```

What it does:
1. Detects the remote OS via `playbash exec` (`uname`, `/etc/os-release`).
2. Generates a self-contained install script based on the OS. The script:
   - Installs prerequisites (`build-essential`, `curl`, `git`, `git-gui`, `gitk`, `micro` on Debian; Xcode CLT on macOS).
   - Installs brew.
   - Installs chezmoi and runs `chezmoi init --apply uhop`.
   - Prints a message to reboot.
3. Copies the script to the remote host (via `playbash put` or `scp`).
4. Prints instructions: **"SSH into `<host>` in another tab and run: `./bootstrap-dotfiles.sh`"**.

The script requires interactive `sudo` and `chezmoi init` prompts (user name, email, GitHub username, whether the machine has a GUI). These are interactive by nature — the user must answer them. This is why `playbash bootstrap` copies the script and instructs rather than trying to run it.

**After the script completes and the host reboots**, it's a fully managed chezmoi host with `doas` configured. Playbash `run`/`push`/`exec` work with full capabilities.

## What stays manual

- **Initial SSH access** — the very first `ssh` connection with a password. No way around this.
- **Post-setup tweaks** — tmux plugin installation (<kbd>Prefix</kbd>+<kbd>I</kbd>), font installation, platform-specific GUI configuration. Documented in the wiki.

## Implementation order

1. `bootstrap-remote` — handles the SSH setup. Standalone bash script, no playbash dependency.
2. `playbash bootstrap` — handles dotfiles installation. Depends on phase 1 being done (or the user having set up SSH manually).
3. Update wiki `Setting-Up-a-New-Machine.md` to reference both tools.
