# Architecture

Personal dotfiles managed by [chezmoi](https://www.chezmoi.io/). Bash-based CLI utilities depend on [options.bash](https://github.com/uhop/options.bash) for option parsing and terminal output. Targets Ubuntu (Debian), Red Hat-like distros (Fedora, RHEL, CentOS, Rocky, Alma), and macOS.

## Project layout

```
dotfiles/                                          # chezmoi source directory
├── .chezmoi.toml.tmpl                             # chezmoi config: OS detection, GUI flag
├── .chezmoiignore                                 # excluded from deployment
├── .editorconfig                                  # 2-space indent, UTF-8, LF
├── .prettierrc                                    # Prettier config for JS files
│
├── dot_bashrc                                     # → ~/.bashrc
├── dot_bash_aliases                               # → ~/.bash_aliases
├── dot_bash_profile                               # → ~/.bash_profile
├── dot_profile                                    # → ~/.profile
├── dot_gitconfig                                  # → ~/.gitconfig
├── dot_inputrc                                    # → ~/.inputrc
├── dot_ackrc                                      # → ~/.ackrc
│
├── dot_config/                                    # → ~/.config/
│   ├── alacritty/alacritty.toml.tmpl              # terminal config (templated)
│   ├── cheat/conf.yml.tmpl                        # cheat config (templated)
│   ├── fastfetch/config.jsonc.tmpl                # system info (templated)
│   ├── ghostty/private_config.tmpl                # terminal config (templated)
│   ├── git/git-completion.bash                    # git completions
│   ├── kitty/private_kitty.conf.tmpl              # terminal config (templated)
│   ├── micro/{bindings,settings,plugins}.json     # editor config
│   ├── nano/private_nanorc                        # editor config
│   ├── systemd/user/                              # → ~/.config/systemd/user/ (Linux only)
│   │   └── email-notify@.service                  # OnFailure= template: email on unit failure
│   └── tmux/tmux.conf                             # tmux config
│
├── private_dot_local/
│   ├── bin/                                       # → ~/.local/bin/ (CLI utilities)
│   │   ├── executable_arx                         # archive viewer/extractor
│   │   ├── executable_bootstrap-dotfiles          # remote host dotfiles installer
│   │   ├── executable_bootstrap-remote            # SSH access setup for remote hosts
│   │   ├── executable_clean-completions           # remove options.bash completion files
│   │   ├── executable_cln.tmpl                    # system cleanup
│   │   ├── executable_dcm                         # docker compose manager with change detection and apparmor retry
│   │   ├── executable_dcms                        # all docker stacks under ~/servers/
│   │   ├── executable_flatpak-install              # flatpak installer dispatching --system vs --user
│   │   ├── executable_goup                        # run command up directory tree
│   │   ├── executable_gpurr                       # git pull all repos
│   │   ├── executable_gpwiki                      # git push wiki
│   │   ├── executable_imop                        # image optimizer/converter
│   │   ├── executable_jot                         # encrypted S3 notes
│   │   ├── executable_mount-raid.tmpl             # NFS mount helper
│   │   ├── executable_ollama-sync                 # update ollama models
│   │   ├── executable_pick                        # interactive command reference (fzf)
│   │   ├── executable_upd.tmpl                    # system updater
│   │   ├── executable_update-dependencies         # project dependency updater
│   │   ├── executable_trim-node-versions.js       # trim old node versions
│   │   ├── executable_update-node-versions.js     # update node major versions
│   │   ├── executable_git-{br,brr,bs,mbs,pick,pull-main,super-clean}  # git helpers
│   │   ├── executable_notify-on-failure           # generic failure email wrapper (launchd/cron)
│   │   ├── executable_notify-playbash             # playbash notification wrapper (all platforms)
│   │   ├── executable_notify-systemd-failure      # systemd OnFailure= email handler (Linux)
│   │   ├── executable_setup-periodic              # periodic task scheduler setup utility
│   │   ├── executable_playbash                    # multi-host playbook runner (Node)
│   │   └── executable_playbash-{daily,weekly,clean,hello,sample}  # playbash playbooks
│   ├── libs/                                      # → ~/.local/libs/
│   │   ├── bootstrap.sh                           # options.bash bootstrap
│   │   ├── detect-distro.sh.tmpl                  # → detect-distro.sh (detection library inlined from .chezmoitemplates/)
│   │   ├── detect-packages.sh.tmpl                # → detect-packages.sh (candidate tables)
│   │   ├── playbash.sh                            # event helpers sourced by playbash playbooks
│   │   ├── playbash-wrap.py                       # cross-platform PTY wrapper (stdin relay for --sudo)
│   │   └── maintenance.sh                         # report_reboot/warn/action + apt-history scan
│   │                                              # (sourced by upd, cln; double-emits to stdout
│   │                                              # AND $PLAYBASH_REPORT JSON-lines sidecar)
│   ├── private_share/                             # → ~/.local/share/ (private permissions)
│   │   ├── playbash/                              # playbash runner modules
│   │   │   ├── render.js                          # COLOR, Rectangle, StatusBoard, sanitizer
│   │   │   ├── inventory.js                       # load + group + self detection
│   │   │   ├── sidecar.js                         # JSON-lines parser + summary + aggregator
│   │   │   ├── staging.js                         # SSH helpers, file staging for vanilla hosts
│   │   │   └── completion.bash                    # bash completion script
│   │   ├── utils/                                 # general Node helpers
│   │   │   ├── comp.js                            # sorting comparator/less-function adapters
│   │   │   ├── semver.js                          # semver parsing
│   │   │   └── nvm.js                             # nvm helper functions
│   │   └── private_gnome-shell/extensions/        # GNOME shell extensions
│   └── vendors/                                   # → ~/.local/vendors/ (fetched via .chezmoiexternal.toml)
│       └── fzf-git.sh                             # fzf git integration (weekly refresh from upstream main)
│
├── .chezmoiexternal.toml                          # external files fetched at apply/update time (fzf-git.sh)
├── .chezmoitemplates/                             # reusable template fragments (not deployed)
│   ├── install-prelude.sh                         # shared header for run_*_install-*.sh scripts
│   ├── detect-distro.sh                           # bootstrap detection library (§1 identity, §2 capabilities, §3 resolver + pkg_ensure, §4 diagnostics)
│   └── detect-packages.sh                         # candidate tables: logical capability → ordered mgr:pkg tuples
│
├── tests/detect/                                  # unit tests for the detection library
│   ├── run-tests.sh                               # harness; discovers test_*.sh, runs each in a subshell
│   ├── lib.sh                                     # assert::eq / assert::ok / assert::fail helpers
│   ├── fixtures/os-release/                       # per-distro /etc/os-release fixtures (11 distros + Silverblue + MicroOS + slim variants)
│   ├── test_identity.sh                           # identity pass across all fixtures
│   ├── test_capabilities.sh                       # OS/env/network/sudo probes (stubbed _which / _run)
│   ├── test_network.sh                            # has_ipv6 + can_reach
│   ├── test_pkgmgr.sh                             # pkgmgr sniff + family-consistency cross-check
│   ├── test_version.sh                            # version normalize + compare
│   ├── test_pkg_probes.sh                         # mgr_register + pkg_avail/has/version/meets
│   ├── test_install.sh                            # _subst_pkgs + pkg_install + install templates
│   ├── test_resolver.sh                           # pkg_resolve + active_managers + DETECT_OPT_OUT / DETECT_ALLOW_SNAP
│   ├── test_ensure.sh                             # pkg_ensure batching + --dry-run + --strict
│   ├── test_overrides.sh                          # apply_overrides (§3.8 decision table) + should_* predicates
│   ├── test_diagnostics.sh                        # summary + report_json (jq-validated when available)
│   └── test_privilege.sh                          # _assert_no_sudo falsifiability guard
│
├── private_dot_ssh/                               # → ~/.ssh/ (SSH config)
├── run_onchange_before_install-packages.sh.tmpl   # package installation
└── run_once_after_install-vim.sh                   # vim setup
```

## Dependency graph

```
options.bash (external)
    ↑
bootstrap.sh                  ← auto-updates options.bash, sources ansi.sh + args.sh + args-help.sh + args-version.sh
    ↑
executable_arx                ← archive viewer/extractor
executable_bootstrap-dotfiles ← remote host dotfiles installer
executable_bootstrap-remote   ← SSH access setup for remote hosts
executable_clean-completions  ← remove options.bash completion files
executable_cln.tmpl           ← system cleanup (apt/dnf, brew, flatpak, docker, node) → maintenance.sh
executable_goup               ← run command in current + parent dirs
executable_imop               ← image optimizer/converter
executable_jot                ← encrypted S3 notes (age, brotli, gzip, etc.)
executable_mount-raid.tmpl    ← NFS mount
executable_ollama-sync        ← ollama model updater
executable_pick               ← interactive command reference (fzf)
executable_upd.tmpl           ← system updater (apt/dnf, snap, flatpak, brew, bun, tmux) → maintenance.sh
```

```
playbash (Node entry, ~/.local/bin/playbash)
    ↓
private_share/playbash/runner.js       ← execution pipeline: spawn, tee, sidecar, fan-out
private_share/playbash/render.js       ← COLOR, Rectangle, StatusBoard, ANSI sanitizer
private_share/playbash/inventory.js    ← inventory load, group expansion, self detection
private_share/playbash/sidecar.js      ← JSON-lines parser, per-host summary, cross-host aggregator
private_share/playbash/staging.js      ← SSH helpers (sshRun), file staging for vanilla hosts
private_share/playbash/transfer.js     ← put/get file transfer over ssh
private_share/playbash/commands.js     ← list, hosts, log, __complete-targets, --bash-completion
private_share/playbash/doctor.js       ← playbash doctor env + per-host diagnostic
private_share/playbash/errors.js       ← die() — user-facing error exit
private_share/playbash/paths.js        ← shared path constants (LOG_DIR, PLAYBOOK_DIR, etc.)
private_share/playbash/shell-escape.js ← shellQuote / shellQuotePath for remote command lines
private_share/playbash/subprocess.js   ← run(): short-lived subprocess helper (doctor, probes)
private_share/playbash/ssh-config.js   ← parseHostNames(): walk ~/.ssh/config + Includes
private_share/playbash/completion.bash ← bash completion (sourced via --bash-completion)

playbash-{daily,weekly,clean,sample,hello}  ← playbook scripts deployed to every host
    ↓
playbash.sh (sourced)                 ← playbash_info/warn/error/action/reboot/step helpers
                                       (writes to $PLAYBASH_REPORT or pretty-prints to stderr)

upd, cln (deployed to every host)
    ↓
maintenance.sh (sourced)              ← report_reboot/warn/action + maintenance::check_apt_since
                                       + apparmor marker file + recovery on script start
                                       (writes both colored output AND $PLAYBASH_REPORT events)
```

```
Periodic task scheduling:

setup-periodic (bash, options.bash)
    ↓
├── systemd: creates ~/.config/systemd/user/*.{service,timer}, enables linger
├── launchd: creates /Library/LaunchDaemons/*.plist (sudo)
└── checks sendmail/msmtp prerequisite

email-notify@.service (systemd template unit)
    ↓
notify-systemd-failure              ← reads journalctl, sends email via sendmail

notify-on-failure                   ← generic wrapper: run command, email on non-zero exit
notify-playbash                     ← playbash wrapper: run playbash --report, email if actionable
    ↓
sendmail (provided by msmtp)
```

```
dot_bashrc
    ↓
dot_bash_aliases              ← aliases, functions (loaded by .bashrc)
```

```
run_onchange_before_install-packages.sh.tmpl
    ↓
├── apt install ...           ← system packages (Debian)
├── dnf install ...           ← system packages (Red Hat-like)
├── brew bundle ...           ← Homebrew packages
├── options.bash clone        ← sparse worktree into ~/.local/share/libs/scripts
├── nvm install stable        ← Node.js
├── bun install               ← Bun runtime
├── tmux plugin manager       ← TPM + plugins
├── sudoers.d/chezmoi         ← NOPASSWD rules per platform (apt/dnf/softwareupdate)
├── doas config               ← /etc/doas.conf (only if doas is installed)
└── etckeeper init            ← /etc git tracking (Linux only)
```

## Chezmoi file naming

| Prefix/Suffix | Meaning | Example |
|---|---|---|
| `dot_` | Replaced with `.` | `dot_bashrc` → `.bashrc` |
| `private_` | Restricted permissions | `private_dot_local` → `.local` (0700) |
| `executable_` | `chmod +x` | `executable_arx` → `arx` |
| `.tmpl` | Go template | `executable_cln.tmpl` → `cln` (processed) |
| `run_onchange_before_` | Runs before apply on content change | Package installer |
| `run_once_after_` | Runs once after apply | Vim setup |

## Template data

Defined in `.chezmoi.toml.tmpl`.

**Top-level keys** (user identity + high-level flags):

| Variable | Type | Example | Purpose |
|---|---|---|---|
| `osFamily` | string | `linux`, `darwin` | Broad OS family (from `.chezmoi.os`) |
| `codespaces` | bool | `false` | Running in GitHub Codespaces |
| `hasGui` | bool | `true` | Machine has a GUI |
| `name`, `email`, `githubUsername` | string | — | User identity |

**Sniffed values** under `.detect.*`, populated from the detection library (see `dev-docs/bootstrap-detection-design.md` for the full spec):

| Variable | Type | Example | Purpose |
|---|---|---|---|
| `.detect.pkgmgr` | string | `apt`, `dnf`, `pacman`, `apk`, `brew`, … | System package manager |
| `.detect.family` | string | `debian`, `rhel`, `arch`, `suse`, `darwin`, … | Distro family (normalised) |
| `.detect.id` | string | `ubuntu`, `fedora`, `ol` | Exact distro ID from `/etc/os-release` |
| `.detect.idLike` | string | `debian`, `fedora rhel`, … | ID_LIKE tokens, space-separated |
| `.detect.versionId`, `.detect.name`, `.detect.arch`, `.detect.uname` | string | — | Assorted identity fields |
| `.detect.initSystem` | string | `systemd`, `launchd`, `openrc`, … | Service manager |
| `.detect.isImmutable`, `.detect.isContainer`, `.detect.isWsl` | bool | — | Environment flags |
| `.detect.hasIpv6` | bool | — | Working IPv6 egress |
| `.detect.sudoGroup`, `.detect.canSudoNopasswd` | string, bool | `sudo` / `wheel` / `admin`, — | Privilege shape |
| `.detect.hasBrew`, `.detect.hasFlatpak`, `.detect.hasSnap`, `.detect.hasNix` | bool | — | Optional package managers |

## Bootstrap: bootstrap.sh

`private_dot_local/libs/bootstrap.sh` bridges dotfiles and options.bash:

1. `git -C ~/.local/share/libs/scripts pull` — auto-update the library.
2. Source `ansi.sh` — ANSI color globals and terminal-aware output.
3. Source `args.sh` — option/command parsing via `getopt`.
4. Source `args-version.sh` — `--version` handler.
5. Source `args-help.sh` — auto-generated colored help screens.
6. Define `echoRun` / `echoRun --bold` — colored command execution with echo.
7. Alias `doas` as `sudo` if available.

## CLI utility conventions

- Every utility starts with `set -euCo pipefail` + `shopt -s expand_aliases`.
- Source `~/.local/libs/bootstrap.sh` for options.bash access.
- Register options with `args::option`, parse with `args::parse "$@"`.
- **`args_cleaned` is an array** — use `set -- "${args_cleaned[@]}"` to restore positional parameters.
- Use `ansi::out` / `ansi::err` for terminal-aware output.
- Use ANSI color globals for styling: `BOLD`, `RESET_ALL`, `FG_CYAN`, `BG_RED`, `BRIGHT_WHITE`, etc.
- Check `args_options` associative array for parsed flags: `[[ -v args_options["-y"] ]]`.
- Check `args_command` for matched subcommand.

## Platform-specific code

Templates use Go conditionals:

```
{{ if eq .detect.pkgmgr "apt" }}
  # Debian/Ubuntu-specific code
{{ else if eq .detect.pkgmgr "dnf" }}
  # Red Hat-like (Fedora, RHEL, CentOS, etc.) code
{{ else if eq .osFamily "darwin" }}
  # macOS-specific code
{{ end }}
```

GUI-dependent code uses `{{ if .hasGui }}`. Use `.detect.id` (exact distro) or `.detect.family` (normalised family) for finer-grained checks.
