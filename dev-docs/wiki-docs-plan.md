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

### Setup pages

| Topic | Page | Status |
|-------|------|--------|
| New machine setup | [Setting Up a New Machine](Setting-Up-a-New-Machine) | ✅ SSH keys, server hardening, dotfiles install, post-setup checklist. |

### Workflow pages

| Topic | Page | Status |
|-------|------|--------|
| Shell basics | [Workflows: general](Workflows-general) | ✅ Terminal setup, CLI editing, navigation, files/dirs, help. |
| Git workflows | [Workflows: git](Workflows-git) | ✅ Feature branches, submodules. Could add: rebasing, tagging, PR workflow. |
| Remote access | [Workflows: remote](Workflows-remote) | ✅ ssht/mosht/ett, nested tmux, playbash crossref. |
| System maintenance | [Workflows: maintenance](Workflows-maintenance) | ✅ upd/cln, Docker Compose, multi-host, diagnostics. |

### Gaps

No remaining gaps. Items previously listed as gaps but now covered:
- Searching → now in Workflows: general (Searching section with tool-choice table).
- Docker workflows → now in Workflows: maintenance.
- Encrypted notes (`jot`) → documented in Utilities.
- Image optimization (`imop`) → documented in Utilities.
- Archive handling (`arx`) → documented in Utilities.
- Node.js version management → documented in Utilities (update-node-versions.js, trim-node-versions.js).
- Multi-host maintenance → now in Workflows: maintenance + Playbash Server Management.

## Bootstrap workflow

✅ [Setting Up a New Machine](Setting-Up-a-New-Machine) documents the full setup flow. `bootstrap-remote` and `bootstrap-dotfiles` automate it. See [bootstrap-plan.md](./done/bootstrap-plan.md) for design rationale.

### Remaining open questions

1. ~~**README vs wiki.** Condensed — platform sections now link to Setting Up a New Machine and Platform Notes.~~

2. **Partial bootstrap.** What if someone only wants the shell aliases, not the full tool suite? The current `run_onchange_before_` is all-or-nothing. May not be worth solving now.

## Related dev-docs

- **[bashrc-optimization.md](./done/bashrc-optimization.md)** — plan to gate completions and tool inits behind `__INTERACTIVE` for faster non-interactive shells. ✅ Done.
- **[bootstrap-plan.md](./done/bootstrap-plan.md)** — automation plan for setting up vanilla machines (SSH hardening, prerequisites, chezmoi init). ✅ Done.
- **[playbash-roadmap.md](./done/playbash-roadmap.md)** — playbash v1–v3 design and implementation. ✅ Done.

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

✅ Option 1 done — tool-choice guidance added to Workflows: general (searching, file managers) and Workflows: maintenance (monitors, disk usage, network). Pruning and alias consolidation deferred.

## Editor choice rationale

✅ Documented in Application Notes (Micro section).

**Micro** was chosen because:
- Small, TUI-based, available in system repositories (`apt install micro`)
- Natural GUI-like keybindings (Ctrl+C/V/X, Ctrl+S, Ctrl+Q) — no modal editing
- Extensible with plugins (fzf integration, prettier, etc.)
- Good fit for users coming from GUI editors who prefer non-vim workflows

Vim is also installed (and configured via `run_once_after_install-vim.sh`) as a fallback — it's the universal default on servers and needed for occasional use, but Micro is the daily driver set in `EDITOR` and `VISUAL`.

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
6. ~~Document SSH key setup, distribution, client config, and server hardening in Workflows: remote.~~
7. ~~Create setup page; move one-time SSH/bootstrap content out of Workflows: remote.~~
8. ~~Implement `bootstrap-remote` and `bootstrap-dotfiles`; update wiki and Utilities.~~
9. ~~Add a "Searching" section to Workflows: general.~~
10. ~~Condense README platform sections to link to wiki.~~
10. ~~Document tool overlap story in workflow pages (which tool for which job).~~
11. ~~Note Micro editor rationale in Application Notes.~~
