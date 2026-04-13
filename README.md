# dotfiles

It all started as a gist to keep track of my dotfiles: https://gist.github.com/uhop/f11632fa81bff6fa4c25300656dce6e7

Now I decided to use [chezmoi](https://www.chezmoi.io/) to manage them across computers.

# Installation

Generic instructions (see platform-specific notes below):

- Install [brew](https://brew.sh/) on MacOS or Linux.
- Install `chezmoi`:
  ```bash
  brew install chezmoi
  ```
- Initialize dotfiles:
  ```bash
  chezmoi init --apply uhop
  ```
- Reboot.

**Important!** If you are not me, change your name and email in the global `git` config:

```bash
git config --global user.name "Your Name"
```

```bash
git config --global user.email "you@example.com"
```

And update your GitHub user name in `.chezmoi.toml.tmpl` and at the bottom of `.bashrc`.

## Maintenance

Three layers of maintenance scripts:

1. **`upd`** &mdash; updates `apt`/`dnf`, `snap`, `flatpak`, `brew`, `bun`. Detects `docker-ce`/AppArmor upgrades and surfaces reboot recommendations; `upd -r` recovers from a `docker-ce` upgrade by restarting `containerd` + `docker` instead of asking for a full reboot.
2. **`cln`** &mdash; cleanups for the same package managers, plus old `node` versions. `upd -c` runs `cln` after `upd`.
3. **`playbash`** &mdash; multi-host playbook runner. Subcommands: `run`, `push`, `debug`, `exec`, `put`, `get`, `list`, `hosts`, `log`, `doctor`. Runs bash playbooks and ad-hoc scripts across an inventory of hosts in parallel, with a per-host live view, aggregated summary, offline detection, and file transfer. The `@self` target runs locally without SSH. `--report` produces a plain-text notification summary. See [Playbash Server Management](https://github.com/uhop/dotfiles/wiki/Playbash-Server-Management).
4. **`setup-periodic`** &mdash; creates systemd timers (Linux) or launchd daemons (macOS) for recurring tasks. Checks for `msmtp` as a prerequisite. Notification wrappers (`notify-playbash`, `notify-on-failure`) handle failure emails. The primary pattern: `setup-periodic daily "playbash run @self daily --report"`.

## Installed tools

The choice of tools and aliases is influenced by:

- https://www.askapache.com/linux/bash_profile-functions-advanced-shell/
- https://dev.to/flrnd/must-have-command-line-tools-109f
- https://remysharp.com/2018/08/23/cli-improved
- https://www.cyberciti.biz/tips/bash-aliases-mac-centos-linux-unix.html
- https://opensource.com/article/22/11/modern-linux-commands
- https://github.com/ibraheemdev/modern-unix
- VIM:
  - https://github.com/amix/vimrc

The following tools are installed and aliased:

- `wget`, `httpie` &mdash; like `curl`.
- `age`, `gpg` &mdash; encryption utilities.
- `meld` &mdash; a visual diff/merge utility.
- `diff-so-fancy` &mdash; a nice `diff` pager.
- `tealdeer`, `cheat` &mdash; a `man` replacement. Alternatives: `tldr`.
- `eza` &mdash; better `ls` (maintained fork of the abandoned `exa`).
- `lsr` &mdash; better and faster `ls` (uses `io_uring` on Linux).
- `bat` &mdash; better `cat`.
- `fd` &mdash; better `find`.
- `ncdu`, `dust` &mdash; better `du`.
- `ag`, `ripgrep` &mdash; better `ack`.
  - `ig` &mdash; like `rg` but interactive, part of `igrep`.
- `tig`, `lazygit` &mdash; text interface for `git`.
  - `onefetch` &mdash; `git` stats.
- `broot` &mdash; better `tree`.
- `prettyping`, `gping` &mdash; better `ping`.
- `htop` &mdash; better `top`.
- `btop` &mdash; better `top`.
- `bottom` &mdash; a system monitor (as `btm`).
- `awscli`, `aws-iam-authenticator`, `kubernetes-cli`, `helm`, `sops`, `gh`, `hub`, `nginx`, `net-tools`, `xh` &mdash; useful utilities for web development.
- `parallel` &mdash; shell parallelization.
- `fzf` &mdash; a command-line fuzzy finder.
- `micro` &mdash; an editor. Alternatives: `nano`.
- `jq` &mdash; JSON manipulations.
- `tmux` &mdash; the venerable terminal multiplexor.
- `golang`, `python3`, `pyenv`, `rustc`, `wabt`, `zig` &mdash; language environments we use and love.
- `brotli` &mdash; better than `gzip`, used by HTTP.
- `mc` &mdash; Midnight Commander for file manipulations.
- `yazi` &mdash; yet another terminal file manager.
- `alacritty` &mdash; no-nonsense terminal.
- `kitty` &mdash; no-nonsense terminal.
- `duf` &mdash; a disk utility.
- `hyperfine` &mdash; benchmarking better than `time`.
- `zoxide` &mdash; better `cd`.
- `node`, `nvm`, `deno`, `bun` &mdash; JavaScript environments.
- `pnpm` &mdash; `node`-compatible package manager.
- `helix` &mdash; a modal text editor.
- `whalebrew` &mdash; like `brew` but for Docker images.
- `xc` &mdash; a task runner.
- `mosh` &mdash; a mobile shell (alternative to `ssh`).
- `et` &mdash; an Eternal Terminal (alternative to `ssh`, not pre-installed).
- `ttyd` &mdash; a tool to share a terminal over the web.
- `lnav` &mdash; a log navigator
- `sd` &mdash; better `sed`.
- `uv` &mdash; fast Python package manager.
- `gcp` &mdash; advanced file copy utility.
- `tree` &mdash; show file directories as trees.
- `doas` &mdash; a (better) alternative to `sudo` (opt-in: install `opendoas` manually if you want it; otherwise passwordless maintenance commands are granted via `/etc/sudoers.d/chezmoi`).
- `etckeeper` &mdash; `git`-backed storage for `/etc` files (Linux only).
- `mas` &mdash; Mac App Store CLI (not pre-installed).
- `sshfs` &mdash; `sftp`-based user-level file system.
- `agrep` &mdash; fuzzy `grep` of the `tre` package.
- `bandwhich`, `bmon` &mdash; real-time network monitoring.
- `q` &mdash; a command-line DNS client.
- `pet` &mdash; a snippet manager.

Check `.bash_aliases` for a list of aliases.

# Platform-specific notes

For full step-by-step instructions (prerequisites, brew, SSH keys, server hardening) see **[Setting Up a New Machine](https://github.com/uhop/dotfiles/wiki/Setting-Up-a-New-Machine)** on the wiki. Platform quirks (fonts, video, clipboard, Docker, LXD) are covered in **[Platform Notes](https://github.com/uhop/dotfiles/wiki/Platform-Notes)**.

Supported platforms: Ubuntu (Debian), Red Hat-like (Fedora, RHEL, CentOS, Rocky, Alma), and macOS. On macOS, install a modern `bash` via `brew install bash` and switch to it &mdash; the system `/bin/bash` is outdated.

# More information

See the [wiki](https://github.com/uhop/dotfiles/wiki) for:

- **[Shell Environment](https://github.com/uhop/dotfiles/wiki/Shell-Environment)** &mdash; `.bashrc` / `.bash_aliases` setup, prompt, completions, navigation
- **[Git Configuration](https://github.com/uhop/dotfiles/wiki/Git-Configuration)** &mdash; aliases, pretty formats, custom git commands
- **[Platform Notes](https://github.com/uhop/dotfiles/wiki/Platform-Notes)** &mdash; fonts, video, clipboard, Docker, LXD, GUI package managers
- **[Application Notes](https://github.com/uhop/dotfiles/wiki/Application-Notes)** &mdash; tmux, Micro, Kitty, GNOME, doas, etckeeper, ufw, TeX/LaTeX, flatpak, CUPS
- **[Utilities](https://github.com/uhop/dotfiles/wiki/Utilities)** &mdash; custom CLI utilities: `upd`, `cln`, `dcm`, `dcms`, `arx`, `jot`, `goup`, `ollama-sync`, git helpers
- **[Playbash Server Management](https://github.com/uhop/dotfiles/wiki/Playbash-Server-Management)** &mdash; multi-host playbook runner: `playbash`, daily/weekly maintenance stacks, inventory + groups, sidecar events
