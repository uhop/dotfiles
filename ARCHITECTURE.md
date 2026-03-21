# Architecture

Personal dotfiles managed by [chezmoi](https://www.chezmoi.io/). Bash-based CLI utilities depend on [options.bash](https://github.com/uhop/options.bash) for option parsing and terminal output. Targets Ubuntu (Debian) and macOS.

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
│   └── tmux/tmux.conf                             # tmux config
│
├── private_dot_local/
│   ├── bin/                                       # → ~/.local/bin/ (CLI utilities)
│   │   ├── executable_arx                         # archive viewer/extractor
│   │   ├── executable_cln.tmpl                    # system cleanup
│   │   ├── executable_goup                        # run command up directory tree
│   │   ├── executable_gpurr                       # git pull all repos
│   │   ├── executable_gpwiki                      # git push wiki
│   │   ├── executable_jot                         # encrypted S3 notes
│   │   ├── executable_mount-raid.tmpl             # NFS mount helper
│   │   ├── executable_ollama-sync                 # update ollama models
│   │   ├── executable_upd.tmpl                    # system updater
│   │   ├── executable_update-dependencies         # project dependency updater
│   │   ├── executable_git-br                      # git branch helper
│   │   ├── executable_git-brr                     # git branch helper
│   │   ├── executable_git-bs                      # git bisect helper
│   │   ├── executable_git-mbs                     # git merge-base helper
│   │   ├── executable_git-pull-main               # git pull main branch
│   │   ├── executable_git-super-clean             # git deep clean
│   │   ├── comp-utils.js                          # sorting comparator/less-function adapters
│   │   ├── nvm-utils.js                           # nvm helper functions
│   │   ├── semver-utils.js                        # semver parsing
│   │   ├── executable_trim-node-versions.js       # trim old node versions
│   │   └── executable_update-node-versions.js     # update node major versions
│   ├── libs/
│   │   └── main.sh                                # options.bash bootstrap
│   ├── vendors/
│   │   └── fzf-git.sh                             # fzf git integration
│   └── private_share/
│       └── private_gnome-shell/extensions/        # GNOME shell extensions
│
├── private_dot_ssh/                               # → ~/.ssh/ (SSH config)
├── run_onchange_before_install-packages.sh.tmpl   # package installation
└── run_once_after_install-vim.sh                   # vim setup
```

## Dependency graph

```
options.bash (external)
    ↑
main.sh (bootstrap)           ← auto-updates options.bash, sources ansi.sh + args.sh + args-help.sh + args-version.sh
    ↑
executable_arx                ← archive viewer/extractor
executable_cln.tmpl           ← system cleanup (apt, brew, flatpak, docker, node)
executable_goup               ← run command in current + parent dirs
executable_jot                ← encrypted S3 notes (age, brotli, gzip, etc.)
executable_mount-raid.tmpl    ← NFS mount
executable_ollama-sync        ← ollama model updater
executable_upd.tmpl           ← system updater (apt, snap, flatpak, brew, bun, tmux)
```

```
dot_bashrc
    ↓
dot_bash_aliases              ← aliases, functions (loaded by .bashrc)
```

```
run_onchange_before_install-packages.sh.tmpl
    ↓
├── apt install ...           ← system packages (Debian only)
├── brew bundle ...           ← Homebrew packages
├── options.bash clone        ← sparse worktree into ~/.local/share/libs/scripts
├── nvm install stable        ← Node.js
├── bun install               ← Bun runtime
├── tmux plugin manager       ← TPM + plugins
├── doas config               ← /etc/doas.conf (if not present)
└── etckeeper init            ← /etc git tracking
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

Defined in `.chezmoi.toml.tmpl`:

| Variable | Type | Example | Purpose |
|---|---|---|---|
| `osId` | string | `linux-ubuntu`, `darwin` | Exact OS identifier |
| `osIdLike` | string | `linux-debian`, `darwin` | OS family for conditionals |
| `wsl` | bool | `false` | Running under WSL |
| `codespaces` | bool | `false` | Running in GitHub Codespaces |
| `hasGui` | bool | `true` | Machine has a GUI |

## Bootstrap: main.sh

`private_dot_local/libs/main.sh` bridges dotfiles and options.bash:

1. `git -C ~/.local/share/libs/scripts pull` — auto-update the library.
2. Source `ansi.sh` — ANSI color globals and terminal-aware output.
3. Source `args.sh` — option/command parsing via `getopt`.
4. Source `args-version.sh` — `--version` handler.
5. Source `args-help.sh` — auto-generated colored help screens.
6. Define `echoRun` / `echoRunBold` — colored command execution with echo.
7. Alias `doas` as `sudo` if available.

## CLI utility conventions

- Every utility starts with `set -euCo pipefail` + `shopt -s expand_aliases`.
- Source `~/.local/libs/main.sh` for options.bash access.
- Register options with `args::option`, parse with `args::parse "$@"`.
- **`args_cleaned` is an array** — use `set -- "${args_cleaned[@]}"` to restore positional parameters.
- Use `ansi::out` / `ansi::err` for terminal-aware output.
- Use ANSI color globals for styling: `BOLD`, `RESET_ALL`, `FG_CYAN`, `BG_RED`, `BRIGHT_WHITE`, etc.
- Check `args_options` associative array for parsed flags: `[[ -v args_options["-y"] ]]`.
- Check `args_command` for matched subcommand.

## Platform-specific code

Templates use Go conditionals:

```
{{ if eq .osIdLike "linux-debian" }}
  # Debian/Ubuntu-specific code
{{ else if eq .osIdLike "darwin" }}
  # macOS-specific code
{{ end }}
```

GUI-dependent code uses `{{ if .hasGui }}`.
