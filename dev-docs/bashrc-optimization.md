# .bashrc non-interactive optimization

**Status: ✅ Done.**

`.bashrc` now gates completions and tool initialization behind `__INTERACTIVE`. Non-interactive shells (e.g., `ssh host some-command`) get only PATH, exports, and aliases.

## What changed

The file is organized into two phases:

### Always (non-interactive safe)
- History, shell options
- Prompt setup (already gated by earlier `__INTERACTIVE` checks)
- Brew shellenv (PATH)
- PATH additions (user bin, util-linux, pyenv, bun, lm studio)
- NVM sourcing (`nvm.sh` — sets up PATH and `NVM_DIR`)
- pyenv PATH and `PYENV_ROOT` (but NOT `pyenv init -`)
- Exports (`EDITOR`, `VISUAL`, `FORCE_COLOR`, etc.)
- `.env` loading
- Aliases (`.bash_aliases`)

### Interactive-only (gated)
- Brew bash completions
- Git completion
- NVM completion
- `pyenv init -` (sets up shell functions, shims)
- doas, xc, zoxide, playbash, broot completions and init
- fzf initialization, completions, fzf-git.sh
- pet setup (functions, keybindings, fzf integration)
- iterm2 shell integration
- `/etc/bash_completion`
- fastfetch

## Design decisions

- **NVM sourcing stays unconditional.** `nvm.sh` sets up PATH and the `nvm` function. Non-interactive scripts that run `node` need the correct version on PATH. Only the NVM *completion* is gated.
- **pyenv split into two parts.** PATH and `PYENV_ROOT` are unconditional (scripts need the right Python). `pyenv init -` (which sets up shell functions and rehash hooks) is interactive-only.
- **Aliases stay unconditional.** Some scripts source `.bashrc` and rely on aliases being available.
