---
name: shell-env
description: "User's shell environment overrides. Many standard commands (ls, cat, rm, cp, mkdir, grep, du, cd) are replaced with enhanced alternatives that behave differently. Consult before running terminal commands, especially with `ls` and file operations. Use `command cmd` to bypass aliases."
---

# Shell Environment Overrides

The user's shell replaces many standard commands with enhanced alternatives. These behave differently from their originals — be aware when running terminal commands.

## Critical rule

Many standard commands are aliased to enhanced replacements or have safety flags added. To run the **original** command (bypassing the alias), use the `command` builtin:

```bash
command cat file.txt   # runs original cat, not bat
command ls             # runs original ls, not eza
command rm file.txt    # runs original rm, not rm -I
command cp src dst     # runs original cp, not cp -iv
command mkdir dir      # runs original mkdir, not mkdir -pv
```

**Always use `command` when the alias behavior would interfere with your intended operation** (e.g., interactive confirmations from `cp -iv` in non-interactive scripts, or bat paging from `cat`).

> **AI agents:** Prefer `command cmd` — it is the POSIX-standard alias bypass and works in **every** tool-based command runner.
>
> The backslash form (`\cp`, `\cat`, …) works in **Claude Code's Bash tool** (verified — `\ls`, `\mkdir -pv`, `\cp -f` all complete cleanly) but **hangs forever in Windsurf** (the Cascade command runner fails to detect process completion). If you're not certain which tool you're running under, use `command cmd`.

## Command replacements

These aliases replace built-in commands with enhanced versions:

| Original | Replacement | Notes |
|---|---|---|
| `ls` | `eza` (with icons, color, sort by type) | `l`, `ll`, `la`, `lla`, `ltr` variants available |
| `cat` | `bat` (or `batcat`) | Syntax highlighting, paging |
| `cd` | `z` (zoxide) | Smart directory jumping (tracks frequency and recency) |
| `grep` | `grep --color=auto` | Also `egrep`, `fgrep`, `diff` |
| `top` | `htop` | |
| `du` | `ncdu` (no args) / real `du` (with args) | Excludes `.git`, `node_modules` |
| `ping` | `sudo prettyping` | |
| `help` | `tldr` | |
| `sudo` | `doas` (if available) | |

## Safety-enhanced commands

These aliases add confirmation or safety flags:

| Command | Alias behavior |
|---|---|
| `rm` | `rm -I --preserve-root` (prompts if deleting more than 3 files) |
| `cp` | `cp -iv` (interactive, verbose) |
| `mv` | `mv -iv` (interactive, verbose) |
| `ln` | `ln -i` (interactive) |
| `mkdir` | `mkdir -pv` (create parents, verbose) |
| `wget` | `wget -c` (resume) |
| `chown`, `chmod`, `chgrp` | `--preserve-root` (Linux only) |

## Git shortcuts

| Alias | Command |
|---|---|
| `gst` | `git status` |
| `gco` | `git checkout` |
| `gcob` | `git checkout -b` |
| `gcm` | `git commit` |
| `gbr` | `git branch` |
| `gpull` | `git pull` |
| `gpush` | `git push` |
| `gsw` | `git switch` (default branch if no args) |
| `gme` | `git merge` (default branch if no args) |
| `gk` | `gitk --all` |
| `lzg` | `lazygit` |

## Utility shortcuts

| Alias | Expands to |
|---|---|
| `mic` | `micro` (editor) |
| `lzd` | `lazydocker` |
| `tre` | `tree` (excludes `node_modules`, `.git`, `venv`, etc.) |
| `gre` | `grep -r` (excludes `node_modules`, `.git`, `dist`, etc.) |
| `h` | `history` |
| `j` | `jobs -l` |
| `path` | prints `$PATH` one entry per line |
| `oports` | lists open listening ports |

## Custom functions

| Function | Usage |
|---|---|
| `zl [dir]` | `cd` + `ls` |
| `mkz dir` / `mkcd dir` | `mkdir -pv` + `cd` |
| `up N` | go up N directories |
| `l. [dir]` | list dotfiles |
| `where "pattern" [path/glob]` | context search in files |
| `upsearch pattern` | search upward from cwd |
| `ssht host [session]` | SSH + tmux attach |
| `rcp` / `rmv` | rsync copy/move with progress bar |

## Available utilities

Installed via Homebrew: `eza`, `bat`, `zoxide`, `fzf`, `micro`, `htop`, `ncdu`, `prettyping`, `tldr`, `broot`, `duf`, `fastfetch`, `lazygit`, `lazydocker`, `rsync`, `nvm`, `pyenv`, `bun`.
