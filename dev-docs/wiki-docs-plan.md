# Wiki documentation plan

A plan for filling out the dotfiles wiki systematically. The goal is to document the *workflows* this project enables — the "why" behind every alias, function, and utility — so a new user (or future-me) can learn the system by problem, not by config file.

## Guiding principle

Each wiki page should answer: **"I need to do X — what does this project give me?"** Reference pages (Shell-Environment, Git-Configuration) list *what* is configured. Workflow pages explain *when and how* to use it.

## Coverage analysis

### Well-documented (reference pages exist)

| Topic | Page | Status |
|-------|------|--------|
| Shell init, aliases, functions | [Shell Environment](Shell-Environment) | ✅ Thorough reference. Needs periodic fact-checks against source. |
| Git config, aliases, pretty log | [Git Configuration](Git-Configuration) | ✅ Complete. Shell alias table deduplicated — now points to Shell-Environment. |
| Platform quirks (Ubuntu, macOS) | [Platform Notes](Platform-Notes) | ✅ Covers post-install steps. |
| App-specific notes (tmux, Micro, Kitty, doas) | [Application Notes](Application-Notes) | ✅ Good coverage. |
| CLI utilities (upd, cln, arx, jot, etc.) | [Utilities](Utilities) | ✅ Full reference for every utility. |
| Playbash runner | [Playbash Server Management](Playbash-Server-Management) | ✅ Comprehensive. |

### Workflow pages

| Topic | Page | Status |
|-------|------|--------|
| Shell basics | [Workflows: general](Workflows-general) | ✅ Terminal setup, CLI editing, navigation, files/dirs, help. |
| Git workflows | [Workflows: git](Workflows-git) | ✅ Feature branches, submodules. Could add: rebasing, tagging, PR workflow. |
| Remote access | [Workflows: remote](Workflows-remote) | ✅ ssht/mosht/ett, nested tmux, playbash crossref. |
| System maintenance | [Workflows: maintenance](Workflows-maintenance) | ✅ upd/cln, Docker Compose, multi-host, diagnostics. |

### Gaps

| Topic | Notes | Priority |
|-------|-------|----------|
| **Searching** | `where`, `upfind`, `upfd`, `upsearch`, `gre`, fzf-git.sh. Already documented in Shell-Environment as a reference; could use a workflow section in Workflows: general showing when to reach for each tool. | Medium |
| **New machine bootstrap** | End-to-end setup of a vanilla machine. Content exists in README and Platform Notes but is scattered. See "Bootstrap workflow" section below. | High |

Items previously listed as gaps but already covered:
- Docker workflows → now in Workflows: maintenance.
- Encrypted notes (`jot`) → documented in Utilities.
- Image optimization (`imop`) → documented in Utilities.
- Archive handling (`arx`) → documented in Utilities.
- Node.js version management → documented in Utilities (update-node-versions.js, trim-node-versions.js).
- Multi-host maintenance → now in Workflows: maintenance + Playbash Server Management.

## Bootstrap workflow

Setting up a vanilla machine is currently documented across three places:

1. **README.md** — generic install steps + Ubuntu/macOS platform-specific sections.
2. **Platform Notes** — post-install configuration (fonts, video, clipboard, Docker).
3. **`run_onchange_before_install-packages.sh.tmpl`** — the actual automation (apt/brew packages, nvm, bun, tmux plugins, doas).

### What exists today

The current flow: install SSH keys → install prerequisites (`build-essential`, `curl`, `git`, `git-gui`, `gitk`, `micro`) → install brew → `brew install chezmoi` → `chezmoi init --apply uhop` → reboot. The `run_onchange_before_` script handles the heavy lifting automatically.

### Open questions

1. **Remote bootstrap.** Can a new machine be set up remotely? The prerequisites step needs `sudo` access. `playbash exec` can run ad-hoc commands on any SSH-reachable host, but the interactive `sudo` prompt is currently detected-and-killed by playbash (by design, to avoid hanging playbooks). Options:
   - A dedicated bootstrap script that runs the prerequisite + brew + chezmoi steps, designed to be `scp`'d and run manually via `ssht`.
   - Extending `playbash exec` with a `--sudo` mode (passwordless sudo via `doas.conf` is only available *after* chezmoi runs).
   - Keeping it manual — the prerequisites step is short and only runs once per machine.

2. **README vs wiki.** The README duplicates Platform Notes for Ubuntu/macOS. Consider condensing README to the quickstart (generic 4-step flow) and linking to a dedicated wiki page for platform details.

3. **Post-bootstrap verification.** No checklist exists for verifying a new machine is fully set up (are all tools working? is the correct Node version active? are tmux plugins installed?). A short verification section would catch silent failures.

4. **Partial bootstrap.** What if someone only wants the shell aliases, not the full tool suite? The current `run_onchange_before_` is all-or-nothing. This may not be worth solving now but is worth noting.

### Proposed action

- Create a **Workflows: bootstrap** wiki page that consolidates the setup narrative from README + Platform Notes into a single walkthrough.
- Condense README's platform sections to a brief summary + link to the wiki page.
- Add a post-bootstrap verification checklist.
- Document the `playbash exec` + `ssht` remote bootstrap path as a known pattern, even if it stays manual.

## .bashrc non-interactive optimization

`.bashrc` currently gates only prompt setup, git-prompt, and fastfetch behind `__INTERACTIVE`. Everything else — completions, tool initialization, `eval` calls — runs unconditionally, even for non-interactive shells (e.g., `ssh host some-command`).

### What should be gated

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

### Implementation approach

Wrap the interactive-only block with the existing `__INTERACTIVE` flag. The early-exit pattern (`[ -z "$PS1" ] && return` at the top) is tempting but would skip PATH setup and exports that non-interactive shells need. Better to expand the existing `if [ "$__INTERACTIVE" == yes ]` blocks to cover completions and tool inits, or reorganize into two clear sections: environment (always) and interactive setup (gated).

An alternative: `.bash_profile` sources `.bashrc` unconditionally. We could move the interactive-only parts out of `.bashrc` into a file that `.bashrc` sources only when interactive. This keeps `.bashrc` fast for non-interactive use.

## Bootstrap automation

### Current manual flow

1. SSH into vanilla machine with password.
2. Set up passwordless SSH certificates, disable password login and root login.
3. Copy-paste prerequisite commands from README.md (`sudo apt install build-essential curl git git-gui gitk micro`, brew install, chezmoi init).
4. Reboot.

### Automation opportunities

**SSH hardening (step 2):** Could be a standalone script that:
- Copies the local SSH public key (`ssh-copy-id` or manual `.authorized_keys`)
- Disables `PasswordAuthentication`, `PermitRootLogin` in `sshd_config`
- Restarts `sshd`

This is a common pattern with well-known pitfalls (locking yourself out). A careful script with dry-run mode would be valuable. Could be an `scp`+`ssh` one-liner run from the local machine, or a utility in `~/.local/bin/`.

**Prerequisites + chezmoi (step 3):** Could be a single bootstrap script that:
- Installs `build-essential`, `curl`, `git`, etc. via `apt`
- Installs brew
- Installs chezmoi and runs `chezmoi init --apply uhop`

This script must run with `sudo` access. It could be `scp`'d to the remote host and run via `ssht`. Playbash can't easily do this because the host has no tooling yet and may require interactive `sudo`.

**Proposed approach:** A `bootstrap-remote` script in `~/.local/bin/` that takes a hostname and:
1. Copies itself + SSH public key to the remote host
2. Runs the prerequisites remotely
3. Does NOT harden SSH (separate concern, should be explicit)

The SSH hardening step remains manual or a separate opt-in script. Doing it wrong has high consequences.

## Tool overlap analysis

The project installs multiple tools for several categories. Some overlap is intentional (different tools for different situations), but the lack of documented guidance makes it unclear when to use which.

### Categories with overlap

| Category | Tools installed | Actively aliased | Story |
|----------|----------------|-----------------|-------|
| **Grep/search** | ag, ripgrep, ig, ack, fd + `gre`, `where`, fzf | `gre`, `where` aliases | No clear guidance. `ripgrep` is fastest; `fzf` is interactive; `where` is a legacy wrapper. |
| **System monitor** | htop, btop, bottom | `top`→`htop` | Three monitors, only htop aliased. btop and bottom installed but no workflow story. |
| **Disk usage** | ncdu, dust, duf | `du`→`ncdu`, `duf` aliased | ncdu for interactive browsing, duf for overview. dust installed but unused. |
| **File managers** | mc, yazi, broot | broot init'd | Three file managers, none prominently featured in workflows. |
| **Better ls** | eza, lsr | `ls`→`eza` | lsr installed but never aliased. |
| **Better ping** | prettyping, gping | `ping`→`prettyping` | gping installed but unused. |
| **Help tools** | tldr (tealdeer), cheat, pet | `help`→`tldr` | All three serve slightly different purposes: tldr for quick reference, cheat for editable sheets, pet for personal snippets. |

### What to do about it

The overlap itself is not necessarily a problem — many tools coexist fine. What's missing is documentation: "use X for this, Y for that." Options:

1. **Document the story** in Workflows pages: for each category, state the primary tool and when alternatives apply. Example: "Use `ripgrep` (`rg`) for code search. `fzf` for interactive filtering. `where` for quick recursive grep when you don't want regex."

2. **Prune unused tools** from the install script. If `dust`, `lsr`, `gping` are never aliased or documented, consider dropping them. They add install time and cognitive overhead.

3. **Consolidate aliases.** The `gre` alias (recursive grep excluding junk dirs) does the same thing `ripgrep` does by default. `where` (find + grep) is slower than `rg`. These could be simplified.

This is a larger effort — start by documenting the intended story, then prune in a follow-up.

## Editor choice rationale

**Micro** was chosen because:
- Small, TUI-based, available in system repositories (`apt install micro`)
- Natural GUI-like keybindings (Ctrl+C/V/X, Ctrl+S, Ctrl+Q) — no modal editing
- Extensible with plugins (fzf integration, prettier, etc.)
- Good fit for users coming from GUI editors who prefer non-vim workflows

Vim is also installed (and configured via `run_once_after_install-vim.sh`) as a fallback — it's the universal default on servers and needed for occasional use, but Micro is the daily driver set in `EDITOR` and `VISUAL`.

This rationale should be noted in Application Notes or Workflows: general.

## Cross-document consistency notes

Audit performed 2026-04-10. Findings addressed:

- ✅ Shell alias table in Git-Configuration.md deduplicated → replaced with crossref to Shell-Environment.
- ✅ Shell-Environment.md factual errors fixed (interactive flag, git completion, PATH dedup, missing tools).
- ⚠️ README.md platform-specific sections duplicate Platform Notes — defer to bootstrap page work.
- ⚠️ Application-Notes tmux section overlaps with Workflows: remote — both kept; Workflows: remote links to Application-Notes for configuration details.

## Work order

1. ~~Fix factual errors in Shell-Environment.md.~~
2. ~~Polish Workflows: git and Workflows: general.~~
3. ~~Split Workflows: general → general + remote + maintenance.~~
4. ~~Deduplicate Git-Configuration shell alias table.~~
5. ~~Fix dcm docs (no `--all`; scans child dirs) and playbash argument order.~~
6. Add a "Searching" section to Workflows: general.
7. Create Workflows: bootstrap wiki page; condense README accordingly.
8. Optimize `.bashrc` for non-interactive shells (gate completions + tool inits behind `__INTERACTIVE`).
9. Write a `bootstrap-remote` script or document the manual remote bootstrap pattern.
10. Document tool overlap story in workflow pages (which tool for which job).
11. Note Micro editor rationale in Application Notes.
12. Update Home.md index as pages are added.
