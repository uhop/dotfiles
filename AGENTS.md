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
├── install.sh                         # curl-pipe entry point: `curl -fsSL <raw url>/install.sh | sh`
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
│   ├── bat/                           # syntax theme shared with delta
│   ├── cheat/
│   ├── fastfetch/
│   ├── fleet-deps/                    # ignore patterns for fleet-deps
│   ├── ghostty/
│   ├── git/
│   ├── kitty/
│   ├── micro/
│   ├── nano/
│   ├── systemd/user/                  # → ~/.config/systemd/user/ (Linux only)
│   │   └── email-notify@.service      # OnFailure= template for generic task failure emails
│   └── tmux/
├── private_dot_local/
│   ├── bin/                           # → ~/.local/bin/ (CLI utilities)
│   │   ├── executable_arx             # Archive viewer/extractor
│   │   ├── executable_bootstrap-dotfiles  # Thin wrapper over install.sh: SSH+curl-pipe for remote, or local self-bootstrap (--from-jot)
│   │   ├── executable_bootstrap-remote    # SSH access setup for remote hosts
│   │   ├── executable_clean-completions   # Remove options.bash completion files
│   │   ├── executable_cln.tmpl        # Cleanup script (apt/dnf, brew, flatpak, docker, node)
│   │   ├── executable_dcm             # Docker compose manager with change detection and apparmor retry
│   │   ├── executable_dcms            # All docker-compose stacks under ~/servers/
│   │   ├── executable_flatpak-install # Flatpak installer, dispatches between --system and --user
│   │   ├── executable_fleet-deps      # Cross-project dependency graph for a GitHub fleet (Node)
│   │   ├── executable_goup            # Run command in current + parent directories
│   │   ├── executable_gpurr           # Git pull all repos
│   │   ├── executable_gpwiki          # Git push wiki
│   │   ├── executable_imop            # Image optimizer/converter
│   │   ├── executable_cxop            # Compression pre-processor (.gz/.br/.zst siblings for HTTP content-negotiation)
│   │   ├── executable_cdn-inv         # CloudFront invalidation CLI (list/find/invalidate by domain alias)
│   │   ├── executable_jot             # Encrypted S3 notes editor
│   │   ├── executable_mount-raid.tmpl # NFS mount helper
│   │   ├── executable_ollama-sync     # Update all ollama models
│   │   ├── executable_pick            # Interactive command reference (fzf)
│   │   ├── executable_upd.tmpl        # System updater (apt/dnf, snap, flatpak, brew, bun)
│   │   ├── executable_update-dependencies   # Update project dependencies
│   │   ├── executable_trim-node-versions.js    # Trim old node versions
│   │   ├── executable_update-node-versions.js  # Update node major versions
│   │   ├── executable_git-*           # Git helper scripts (incl. git-pick → pick git)
│   │   ├── executable_notify-on-failure   # Generic failure wrapper (launchd/cron)
│   │   ├── executable_notify-playbash     # Playbash notification wrapper (all platforms)
│   │   ├── executable_notify-systemd-failure  # systemd OnFailure= email handler
│   │   ├── executable_setup-periodic      # Periodic task scheduler setup utility
│   │   ├── executable_playbash        # Multi-host playbook runner (Node)
│   │   └── executable_playbash-{daily,weekly,clean,hello,sample}  # playbash playbooks
│   ├── libs/
│   │   ├── bootstrap.sh               # Sources options.bash core modules
│   │   ├── detect-distro.sh.tmpl      # → ~/.local/libs/detect-distro.sh (detection library, inlined from .chezmoitemplates/)
│   │   ├── detect-packages.sh.tmpl    # → ~/.local/libs/detect-packages.sh (candidate tables)
│   │   ├── playbash.sh                # Sidecar/event helpers sourced by playbash playbooks
│   │   ├── playbash-wrap.py           # Cross-platform PTY wrapper (stdin relay for --sudo)
│   │   └── maintenance.sh             # report_reboot/warn/action helpers + apt-history scanning
│   │                                  # (sourced by upd, cln; writes both colored output and
│   │                                  # JSON-lines events to $PLAYBASH_REPORT when set)
│   ├── private_share/                 # → ~/.local/share/ (private permissions)
│   │   ├── playbash/                  # playbash runner modules (runner, render, inventory, sidecar, staging, transfer, commands, doctor, capabilities, errors, paths, shell-escape, subprocess, ssh-config, completion)
│   │   ├── utils/                     # general Node helpers (comp, semver, nvm)
│   │   └── private_gnome-shell/       # GNOME shell extensions
│   └── vendors/                       # → ~/.local/vendors/ (fetched via .chezmoiexternal.toml)
│       └── fzf-git.sh                 # fzf git integration (weekly refresh from upstream main)
├── .chezmoiexternal.toml              # external files fetched at apply/update time
├── .chezmoitemplates/                 # reusable template fragments (not deployed)
│   ├── install-prelude.sh             # shared header for run_*_install-*.sh scripts
│   ├── detect-distro.sh               # bootstrap detection library (identity + capabilities + resolver)
│   └── detect-packages.sh             # candidate tables (logical-cap → mgr:pkg tuples) for the resolver
├── tests/detect/                      # unit tests for the detection library
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

Template data is defined in `.chezmoi.toml.tmpl`. Top-level keys:
- `osFamily` — `linux` or `darwin`
- `codespaces` — true if running in GitHub Codespaces
- `hasGui` — whether the machine has a GUI
- `name`, `email`, `githubUsername` — user identity

Sniffed values from the detection library under `.detect.*` (see `dev-docs/bootstrap-detection-design.md` for the full list):
- `.detect.pkgmgr` — `apt`, `dnf`, `pacman`, `zypper`, `apk`, `brew`, `pkg`, …
- `.detect.family` — `debian`, `rhel`, `arch`, `suse`, `alpine`, `darwin`, `bsd`, …
- `.detect.id` — exact distro ID from `/etc/os-release` (e.g., `ubuntu`, `fedora`, `ol`)
- `.detect.idLike` — ID_LIKE space-separated tokens
- `.detect.versionId`, `.detect.name`, `.detect.arch`, `.detect.uname`
- `.detect.initSystem`, `.detect.isImmutable`, `.detect.isContainer`, `.detect.isWsl`
- `.detect.hasIpv6`, `.detect.sudoGroup`, `.detect.canSudoNopasswd`
- `.detect.hasBrew`, `.detect.hasFlatpak`, `.detect.hasSnap`, `.detect.hasNix`

## Critical rules

- **Minimal external dependencies.** Prefer standard system tools and already-available solutions over adding new packages. Every external dependency must be explicitly discussed, justified, approved, and documented (what and why). When in doubt, code it rather than import it.
- **Bash 4.0+** for all shell scripts. Start with `#!/usr/bin/env bash`.
- **`set -euCo pipefail`** and **`shopt -s expand_aliases`** at the top of every utility script.
- **Do not add comments or remove comments** unless explicitly asked.
- **Do not modify or delete test scripts** without understanding what they verify.
- **Bash utilities with options or non-trivial output must use `options.bash`** (via `. ~/.local/libs/bootstrap.sh`). It handles option parsing, help screens, colored output, terminal-aware formatting, and shell completions (bash today; zsh/fish in the future). It is a controlled dependency (same author) and should be the default choice over hand-rolled argument parsing or raw `echo`/`printf` for user-facing output. If a utility pattern exposes a generic gap in options.bash, flag it — improvements flow back to the library.
- **`args_cleaned` is an array.** Use `set -- "${args_cleaned[@]}"` (not `eval set -- "${args_cleaned}"`).
- Templates (`.tmpl` files) use Go template syntax with chezmoi data. Guard package-manager blocks with `{{ if eq .detect.pkgmgr "apt" }}` / `{{ if eq .detect.pkgmgr "dnf" }}`; use `{{ if eq .osFamily "linux" }}` / `{{ if eq .osFamily "darwin" }}` for OS-level conditionals; use `{{ if eq .detect.id "fedora" }}` (or `.detect.family`) for distro-specific checks.
- Files listed in `.chezmoiignore` are not deployed to target machines.
- `doas` is aliased to `sudo` when available (in `dot_bash_aliases` and `bootstrap.sh`).

## Code style

- 2-space indentation (`.editorconfig`).
- Shell functions use either `name()` style (aliases, helpers) or `module::name` style (options.bash convention).
- `echoRun` / `echoRun --bold` for colored command execution with echo.
- `ansi::out` / `ansi::err` / `ansi::warn` for terminal-aware output (auto-strips ANSI when piped). Use `ansi::warn` for non-fatal stderr messages (returns 0, safe under `set -e`); `ansi::err` returns 1 (exits under `set -e`).
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

## dev-docs conventions

The `dev-docs/` directory holds active design documents — long-lived reference for "what" and "why." Completed plans and historical records live in the Obsidian vault under `projects/dotfiles/done/`.

- **`<feature>-design.md`** — problem statement, constraints, research findings, decisions and their rationale, open questions, criticism. Durable — useful months later when revisiting a feature.
- New implementation plans start as `<feature>-plan.md` in `dev-docs/`. When complete, they move to the vault (`projects/dotfiles/done/`).

## Key conventions

- Do not hardcode paths — use `$HOME`, `~`, or `$(brew --prefix)`.
- Platform-specific code goes in `.tmpl` files guarded by chezmoi template conditionals.
- `sudo` operations check for group membership first (`groups "$(id -un)" | grep -qE '\b(sudo|admin|wheel)\b'`).
- Node.js helper modules live under `private_share/utils/` (general) and `private_share/playbash/` (runner-specific). They deploy to `~/.local/share/utils/` and `~/.local/share/playbash/` respectively. Executables in `bin/` import them via relative paths like `../share/utils/nvm.js`.
- Maintenance scripts (`upd`, `cln`) source `~/.local/libs/maintenance.sh` for shared `report_reboot` / `report_warn` / `report_action` helpers. Each helper prints a colored message via options.bash AND writes a JSON-lines event to `$PLAYBASH_REPORT` when the script runs under the playbash runner. The helpers do not depend on `playbash.sh`; the JSON writer is inlined.
- The playbash runner (`~/.local/bin/playbash`) is a multi-host playbook runner (v1–v3 complete, v3.4+). Subcommands: `run`, `push`, `debug`, `exec`, `put`, `get`, `list`, `hosts`, `log`, `doctor`. Targets always come first: `playbash <cmd> <targets> <rest>`. The special target `@self` resolves to the local hostname and implies `--self` — used for scheduled local runs. Options include `--sudo` (prompt once for a password; for run/exec/push/debug injects via PTY stdin relay; for put/get wraps remote commands with `sudo -S` and prepends the password to stdin) and `--report` (writes a plain-text summary of actionable events to stdout for notification wrappers). `log` supports `--stats` (per-host/per-command breakdown with `--by-command`) and `--prune AGE` (dry-run by default, `--apply` to delete, `--verbose` to list files; ages like `2w`, `7d`, `24h`). `doctor` includes run log file count and size and probes per-host `zstd` availability (warms the capability cache at `~/.cache/playbash/capabilities/<host>.json`). Every byte-transport path in playbash — directory `put`/`get` (tar), single-file `put`/`get`, directory staging, and single-file staging (wrapper/helper/custom playbook pushes) — compresses with zstd when both ends have it; single-file paths compress unconditionally and trade ~1-2% framing overhead on already-compressed content for consistency. Falls back to raw transport if either side lacks zstd — never fails a transfer on a capability miss. Inventory hosts are managed; bare ssh aliases get playbooks pushed automatically. See [Playbash Server Management](https://github.com/uhop/dotfiles/wiki/Playbash-Server-Management) on the wiki and [`dev-docs/playbash-design.md`](./dev-docs/playbash-design.md) for technical rationale.
- Periodic task scheduling uses `setup-periodic` to create systemd timers (Linux) or launchd system daemons (macOS). The primary pattern is `playbash run @self daily --report` on each managed host. Notification wrappers (`notify-playbash`, `notify-on-failure`, `notify-systemd-failure`) handle failure emails via msmtp/sendmail. See [`dev-docs/periodic-tasks-design.md`](./dev-docs/periodic-tasks-design.md) for rationale.
- `flatpak-install` dispatches between `--system` and `--user` scopes with dedup across both. `--system` is chosen when the managed polkit rule at `/usr/local/share/polkit-1/rules.d/90-flatpak-ssh.rules` is present AND the user is in `sudo`/`wheel` (polkit handles auth, works over SSH), OR when `sudo -n true` succeeds (wrapped in `sudo -n flatpak install --system ...` to bypass polkit). Falls back to `--user` otherwise. Probes live under the `detect::flatpak_*` namespace in `.chezmoitemplates/detect-distro.sh` (deployed to `~/.local/libs/detect-distro.sh`); the CLI sources the detection library directly. See design doc §3.10.1.1.
- Git diff viewers: **delta** is the pager (`core.pager`, `interactive.diffFilter`, `pager.diff`), theme `Monokai Extended` (shared with `bat` via `dot_config/bat/config` → `~/.config/bat/config` so diff and cat render identically), inline layout by default (laptop-first). Side-by-side is on demand via the `[delta "wide"]` feature — `git dw` aliases `-c delta.features=wide diff`, and `-c delta.features=wide <anything>` works ad-hoc. **difftastic** is on demand for structural/AST diffs — `diff.tool = difftastic` + `difftool.difftastic.cmd = difft "$LOCAL" "$REMOTE"`, invoked via `git dft` (alias for `difftool`). Both installed via brew (`git-delta`, `difftastic`) — single cross-platform install path. `diff-so-fancy` was removed 2026-04-18. The `chezmoi diff --no-pager` discipline still applies to delta since it's still less-wrapped on output.
- Third-party vendored scripts under `~/.local/vendors/` are fetched by chezmoi from upstream via `.chezmoiexternal.toml` (currently `fzf-git.sh`, weekly refresh tracking `main`). Do not commit upstream copies to the repo — add new vendors as external entries so `chezmoi update` pulls fresh blobs. Consumers (`.bashrc` for fzf-git.sh) must guard sourcing with `[ -s path ] && . path || true` so hosts without network at first apply degrade cleanly.
- Remote-GUI tooling: client side — `freerdp` (xfreerdp3) on every `.hasGui` host (apt `freerdp3-x11` with `freerdp2-x11` fallback, dnf `freerdp`, brew `freerdp`) + `waypipe` in the general apt + dnf lists. Server side — a `remoteDesktop` role prompt in `.chezmoi.toml.tmpl` (`client` | `server` | `both` | `none`, defaults to `client` on GUI hosts) gates two `run_onchange_after_install-grd*.sh.tmpl` scripts. `run_onchange_after_install-grd.sh.tmpl` configures the **system-mode** daemon — generates a self-signed TLS cert+key, runs `grdctl --system rdp enable / disable-view-only / set-port 3389 / set-tls-cert / set-tls-key`, and enables the `gnome-remote-desktop.service` system unit when `.detect.desktop == "gnome"` AND role is `server`/`both`. Credentials are never baked into source; when passwordless sudo isn't available, or when sudo ran but no credentials are set yet, the script writes `/tmp/finish-grd-setup.sh` — an idempotent helper that prompts interactively (`read -rp` / `read -rsp`) for GRD username + password and supplies them to `grdctl` directly (no `<grd-user>`/`<grd-password>` placeholder strings the operator could accidentally paste as literals). `run_onchange_after_install-grd-firewall.sh.tmpl` opens UFW port 3389 when UFW is active; prints firewalld/iptables/nftables hints otherwise. `detect::` exposes `detect::desktop` (gnome/kde/xfce/cinnamon/mate/lxqt/lxde/sway/hyprland/i3/budgie/aqua/headless/unknown) + `detect::has_grd` / `has_sunshine` / `has_xrdp` probes, all in `report_json`. See the [Remote GUI](https://github.com/uhop/dotfiles/wiki/Remote-GUI) wiki page.
- Bootstrap entry points split: **`install.sh`** at the repo root is the authoritative curl-pipe entry (`curl -fsSL https://raw.githubusercontent.com/uhop/dotfiles/main/install.sh \| sh`). POSIX `sh`, capability-probes for `apt-get`/`dnf`/`pacman`/`zypper` (not ID-based case statements — same principle as the detect library), installs OS prereqs + Homebrew + chezmoi, then runs `chezmoi init --apply`. Accepts `-y/--yes` (unattended), `--repo owner/repo`, `--branch <br>`. **`bootstrap-dotfiles`** (in `bin/`) is a thin ~170-line wrapper: remote mode SSHes to `<host>` and pipes `install.sh` over with `--yes`; `--from-jot <prefix>` runs `install.sh` locally then invokes `jot-deploy`. All OS-specific logic lives in `install.sh`; `bootstrap-dotfiles` owns only the surrounding flow (SSH reachability check, jot pre-flight, jot-deploy tail).
- Bootstrap detection library lives at `.chezmoitemplates/detect-distro.sh` + `.chezmoitemplates/detect-packages.sh` (sourced into `bootstrap-dotfiles`, `.chezmoi.toml.tmpl`, and `run_onchange_*` via `includeTemplate` or inline `{{ template }}`). Four sections: §1 identity (`detect::identity`, `family_contains`, `is_version_at_least`), §2 capabilities (`pkgmgr`, `is_immutable`, `is_container`, `is_wsl`, `has_ipv6`, `sudo_group`, `can_sudo_nopasswd`, `has_brew`/`has_flatpak`/`has_snap`/`has_nix`, family-consistency cross-check), §3 package resolution (`mgr_register`, `pkg_avail`/`pkg_has`/`pkg_version`/`pkg_meets`/`pkg_install`, `pkg_resolve <capability>`, `pkg_ensure [--dry-run] [--strict] <caps…>`, `apply_overrides` per §3.8 decision table), §4 diagnostics (`summary`, `report_json`). Candidate tables keyed by logical capability (e.g. `c_toolchain`, `micro_editor`, `git`, `jq`, `lxd`, `kubectl`) live in `detect-packages.sh`. Sourcing is idempotent (`__DETECT_DISTRO_LOADED` / `__DETECT_PACKAGES_LOADED`). Snap is opt-in via `DETECT_ALLOW_SNAP=1`; managers can be vetoed via `DETECT_OPT_OUT`. Tests at `tests/detect/` — run with `bash tests/detect/run-tests.sh`. Full design in [`dev-docs/bootstrap-detection-design.md`](./dev-docs/bootstrap-detection-design.md).
