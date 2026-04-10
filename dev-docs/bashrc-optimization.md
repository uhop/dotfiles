# .bashrc non-interactive optimization

`.bashrc` currently gates only prompt setup, git-prompt, and fastfetch behind `__INTERACTIVE`. Everything else — completions, tool initialization, `eval` calls — runs unconditionally, even for non-interactive shells (e.g., `ssh host some-command`).

## What should be gated

**High priority** (expensive `eval` or subprocess spawns):
- NVM initialization (`nvm.sh` + completions) — spawns a subshell
- pyenv init — spawns a subshell
- fzf initialization — multiple `eval` calls + keybinding setup
- pet setup — keybindings and function definitions, interactive-only

**Medium priority** (unnecessary for non-interactive):
- All bash completions (brew, git, playbash, doas, xc)
- zoxide init, broot init
- fzf-git.sh
- iTerm2 shell integration

**Keep unconditional:**
- Brew shellenv (needed for PATH in non-interactive scripts)
- PATH additions, exports, aliases (scripts may source `.bashrc` and rely on these)
- `.env` loading

## Implementation approach

Wrap the interactive-only block with the existing `__INTERACTIVE` flag. The early-exit pattern (`[ -z "$PS1" ] && return` at the top) is tempting but would skip PATH setup and exports that non-interactive shells need. Better to expand the existing `if [ "$__INTERACTIVE" == yes ]` blocks to cover completions and tool inits, or reorganize into two clear sections: environment (always) and interactive setup (gated).

An alternative: `.bash_profile` sources `.bashrc` unconditionally. We could move the interactive-only parts out of `.bashrc` into a file that `.bashrc` sources only when interactive. This keeps `.bashrc` fast for non-interactive use.
