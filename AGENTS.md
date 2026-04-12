# AGENTS.md — dotfiles

> Personal dotfiles managed by [chezmoi](https://www.chezmoi.io/). Bash-based CLI utilities use the [options.bash](https://github.com/uhop/options.bash) library for option parsing and rich terminal output. Targets Ubuntu (Debian), Red Hat-like distros (Fedora, RHEL, CentOS, Rocky, Alma), and macOS.

For project structure and module layout see [ARCHITECTURE.md](./ARCHITECTURE.md).
For a compact reference of all utilities see [llms.txt](./llms.txt).

## Setup

This repo is a chezmoi source directory. Apply with:

```bash
brew install chezmoi
chezmoi init --apply uhop
```

On first run, `run_onchange_before_install-packages.sh.tmpl` installs system packages via `apt`/`dnf`/`brew`. Subsequent run scripts clone `options.bash` as a sparse worktree into `~/.local/share/libs/scripts`, install `nvm`, `bun`, `tmux` plugins, and write `/etc/sudoers.d/chezmoi` with NOPASSWD rules for maintenance commands. `doas` is opt-in: install `opendoas` manually and `run_onchange_after_install-doas.sh.tmpl` will manage `/etc/doas.conf`.

## Project structure

```
dotfiles/                              # chezmoi source directory
├── .chezmoi.toml.tmpl                 # chezmoi config template (OS detection, GUI flag)
├── .chezmoiignore                     # files excluded from deployment
├── dot_bashrc                         # → ~/.bashrc (shell init, PATH, completions)
├── dot_bash_aliases                   # → ~/.bash_aliases (aliases, functions)
├── dot_bash_profile                   # → ~/.bash_profile
├── dot_profile                        # → ~/.profile
├── dot_gitconfig                      # → ~/.gitconfig
├── dot_inputrc                        # → ~/.inputrc
├── dot_ackrc                          # → ~/.ackrc
├── dot_config/                        # → ~/.config/ (app configs)
│   ├── alacritty/
│   ├── cheat/
│   ├── fastfetch/
│   ├── ghostty/
│   ├── git/
│   ├── kitty/
│   ├── micro/
│   ├── nano/
│   └── tmux/
├── private_dot_local/
│   ├── bin/                           # → ~/.local/bin/ (CLI utilities)
│   │   ├── executable_arx             # Archive viewer/extractor
│   │   ├── executable_cln.tmpl        # Cleanup script (apt/dnf, brew, flatpak, docker, node)
│   │   ├── executable_dcm             # Single docker compose runner with retry-on-apparmor
│   │   ├── executable_dcms            # All docker-compose stacks under ~/servers/
│   │   ├── executable_goup            # Run command in current + parent directories
│   │   ├── executable_gpurr           # Git pull all repos
│   │   ├── executable_gpwiki          # Git push wiki
│   │   ├── executable_jot             # Encrypted S3 notes editor
│   │   ├── executable_mount-raid.tmpl # NFS mount helper
│   │   ├── executable_ollama-sync     # Update all ollama models
│   │   ├── executable_upd.tmpl        # System updater (apt/dnf, snap, flatpak, brew, bun)
│   │   ├── executable_update-dependencies   # Update project dependencies
│   │   ├── executable_git-*           # Git helper scripts
│   │   ├── executable_playbash        # Multi-host playbook runner (Node)
│   │   └── executable_playbash-{daily,weekly,hello,sample}  # playbash playbooks
│   ├── libs/
│   │   ├── bootstrap.sh               # Sources options.bash core modules
│   │   ├── playbash.sh                # Sidecar/event helpers sourced by playbash playbooks
│   │   ├── playbash-wrap.py           # Cross-platform PTY wrapper (stdin relay for --sudo)
│   │   └── maintenance.sh             # report_reboot/warn/action helpers + apt-history scanning
│   │                                  # (sourced by upd, cln; writes both colored output and
│   │                                  # JSON-lines events to $PLAYBASH_REPORT when set)
│   ├── private_share/                 # → ~/.local/share/ (private permissions)
│   │   ├── playbash/                  # playbash runner modules (runner, render, inventory, sidecar, staging, transfer, commands, doctor, errors, paths, shell-escape, subprocess, ssh-config, completion)
│   │   ├── utils/                     # general Node helpers (comp, semver, nvm)
│   │   └── private_gnome-shell/       # GNOME shell extensions
│   └── vendors/
│       └── fzf-git.sh                 # fzf git integration
├── private_dot_ssh/                   # → ~/.ssh/ (SSH config)
├── run_onchange_before_install-packages.sh.tmpl  # Package installation script
└── run_once_after_install-vim.sh      # Vim setup
```

## Chezmoi naming conventions

Chezmoi uses special prefixes in source file names:

- **`dot_`** → `.` (e.g., `dot_bashrc` → `~/.bashrc`)
- **`private_`** → file/dir with restricted permissions (e.g., `private_dot_local` → `~/.local`)
- **`executable_`** → file is `chmod +x` (e.g., `executable_arx` → `~/.local/bin/arx`)
- **`.tmpl`** suffix → Go template processed with chezmoi data (OS, GUI flag, etc.)
- **`run_onchange_before_`** → script runs before apply when its content changes
- **`run_once_after_`** → script runs once after apply

Template data is defined in `.chezmoi.toml.tmpl`:
- `osId` — e.g., `linux-ubuntu`, `linux-fedora`, `darwin`
- `osIdLike` — e.g., `linux-debian`, `linux-rhel`, `linux-fedora`, `darwin`
- `osFamily` — `linux` or `darwin`
- `pkgManager` — `apt`, `dnf`, or `brew-only` (derived from `osIdLike`)
- `wsl` — true if running under WSL
- `codespaces` — true if running in GitHub Codespaces
- `hasGui` — whether the machine has a GUI

## Critical rules

- **Bash 4.0+** for all shell scripts. Start with `#!/usr/bin/env bash`.
- **`set -euCo pipefail`** and **`shopt -s expand_aliases`** at the top of every utility script.
- **Do not add comments or remove comments** unless explicitly asked.
- **Do not modify or delete test scripts** without understanding what they verify.
- All CLI utilities that use `options.bash` source it via `. ~/.local/libs/bootstrap.sh`.
- **`args_cleaned` is an array.** Use `set -- "${args_cleaned[@]}"` (not `eval set -- "${args_cleaned}"`).
- Templates (`.tmpl` files) use Go template syntax with chezmoi data. Guard package-manager blocks with `{{ if eq .pkgManager "apt" }}` / `{{ if eq .pkgManager "dnf" }}`; use `{{ if eq .osFamily "linux" }}` / `{{ if eq .osFamily "darwin" }}` for OS-level conditionals.
- Files listed in `.chezmoiignore` are not deployed to target machines.
- `doas` is aliased to `sudo` when available (in `dot_bash_aliases` and `bootstrap.sh`).

## Code style

- 2-space indentation (`.editorconfig`).
- Shell functions use either `name()` style (aliases, helpers) or `module::name` style (options.bash convention).
- `echoRun` / `echoRun --bold` for colored command execution with echo.
- `ansi::out` / `ansi::err` for terminal-aware output (auto-strips ANSI when piped).
- ANSI color globals (`RED`, `BOLD`, `RESET_ALL`, `FG_CYAN`, `BG_RED`, etc.) are available in all utilities that source `bootstrap.sh`.

## CLI utility pattern

Every `options.bash`-based utility in `private_dot_local/bin/` follows this pattern:

```bash
#!/usr/bin/env bash

set -euCo pipefail
shopt -s expand_aliases

. ~/.local/libs/bootstrap.sh

script_dir="$(dirname "$(readlink -f "$0")")"
script_name=$(basename "$0")

args::program "$script_name" "1.0" "Description"

args::option "-v, --version" "Show version"
args::option "-h, --help" "Show help"

args::parse "$@"
set -- "${args_cleaned[@]}"

# ... script logic ...
```

## Bootstrap: bootstrap.sh

`private_dot_local/libs/bootstrap.sh` is the bridge between dotfiles and options.bash:

1. Auto-updates `options.bash` from git on every invocation.
2. Sources core modules: `ansi.sh`, `args.sh`, `args-version.sh`, `args-help.sh`.
3. Defines `echoRun` / `echoRun --bold` for colored command execution.
4. Aliases `doas` as `sudo` if available.

## options.bash dependency

The library is cloned as a sparse worktree to `~/.local/share/libs/scripts`:

```bash
git clone --filter=blob:none --sparse https://github.com/uhop/options.bash scripts
git sparse-checkout set --no-cone '/*.sh' '/README.md'
```

Key modules used by dotfiles utilities:
- **`args.sh`** — CLI option/command parsing via `getopt`
- **`args-help.sh`** — auto-generated colored help screens
- **`args-version.sh`** — `--version` handler
- **`ansi.sh`** — ANSI escape codes, color globals, terminal-aware output

For the full `options.bash` API see [its wiki](https://github.com/uhop/options.bash/wiki).

## Key conventions

- Do not hardcode paths — use `$HOME`, `~`, or `$(brew --prefix)`.
- Platform-specific code goes in `.tmpl` files guarded by chezmoi template conditionals.
- `sudo` operations check for group membership first (`groups "$(id -un)" | grep -qE '\b(sudo|admin|wheel)\b'`).
- Node.js helper modules live under `private_share/utils/` (general) and `private_share/playbash/` (runner-specific). They deploy to `~/.local/share/utils/` and `~/.local/share/playbash/` respectively. Executables in `bin/` import them via relative paths like `../share/utils/nvm.js`.
- Maintenance scripts (`upd`, `cln`) source `~/.local/libs/maintenance.sh` for shared `report_reboot` / `report_warn` / `report_action` helpers. Each helper prints a colored message via options.bash AND writes a JSON-lines event to `$PLAYBASH_REPORT` when the script runs under the playbash runner. The helpers do not depend on `playbash.sh`; the JSON writer is inlined.
- The playbash runner (`~/.local/bin/playbash`) is a multi-host playbook runner (v1–v3 complete). Subcommands: `run`, `push`, `debug`, `exec`, `put`, `get`, `list`, `hosts`, `log`, `doctor`. Targets always come first: `playbash <cmd> <targets> <rest>`. Options include `--sudo` (prompt once for a password, inject the same password on every host when sudo/doas asks). Inventory hosts are managed; bare ssh aliases get playbooks pushed automatically. See [Playbash Server Management](https://github.com/uhop/dotfiles/wiki/Playbash-Server-Management) on the wiki, [`dev-docs/playbash-design.md`](./dev-docs/playbash-design.md) for technical rationale, and [`dev-docs/done/playbash-roadmap.md`](./dev-docs/done/playbash-roadmap.md) for the milestone log.
