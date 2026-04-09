# AI agent skills

How AI-agent "skills" (Claude Code, Windsurf) are managed in this dotfiles repo, deployed across machines, and shared between tools.

## What a skill is

A skill is a small markdown file with YAML frontmatter that an AI coding agent loads at startup and uses as context for specific tasks. The format is shared between Claude Code and Windsurf:

```markdown
---
name: shell-env
description: One-line summary the agent uses to decide when to load this skill.
---

# Skill body

Markdown content the agent reads when the skill is invoked.
```

Skills currently managed here:

- **`shell-env`** — warns AI agents about the user's heavily-aliased shell (`cp`, `mv`, `rm`, `ln`, `mkdir` are interactive/verbose; use `command cmd` to bypass). Also documents which `\cmd` backslash bypass is safe in which tool.
- **`docs-review`** — markdown English review (brevity, clarity, what to never touch).
- **`wiki-conventions`** — wiki page naming rules (Unicode hyphen vs ASCII dash, modules vs components, etc.).

Add more by dropping a `<name>/SKILL.md` file in the chezmoi source — see [Adding a new skill](#adding-a-new-skill).

## Architecture

Claude Code is the canonical consumer; Windsurf is bridged via symlink. Single source of truth lives in this chezmoi source tree.

```
chezmoi source                              deployed to                       used by
─────────────────────────────────────────   ───────────────────────────────   ─────────────
private_dot_claude/skills/<name>/SKILL.md → ~/.claude/skills/<name>/SKILL.md  Claude Code
                                            ~/.codeium/windsurf/skills        Windsurf
                                            └─ symlink → ~/.claude/skills/    (Cascade)
private_dot_claude/settings.json          → ~/.claude/settings.json           Claude Code
```

The Windsurf-side symlink is created by `run_once_after_link-windsurf-skills.sh` after every `chezmoi apply` (it only runs once per machine but re-runs are idempotent no-ops).

### Why claude-first

The user works primarily in Claude Code. Windsurf is a secondary/occasional tool. Putting the real files at `~/.claude/skills/` and bridging Windsurf via symlink means:

- New skills are added in one place.
- Edits propagate immediately to both tools.
- Removing Windsurf entirely later is trivial (delete the bridge).
- Adding a third tool (e.g., `~/.config/another-agent/skills/`) is one more symlink in the bridge script.

### Why chezmoi

Skills are configuration. They live in the chezmoi source like everything else:

- Versioned, reviewable diffs through normal git.
- Deployed to every managed machine via `chezmoi update`.
- One-command bootstrap on a new machine — same flow as `~/.bashrc`, `~/.gitconfig`, etc.
- No separate "copy from old machine" step.

## Migration on a new machine

On any machine where you `chezmoi init --apply uhop` (or `chezmoi update` on an already-initialized machine), the skills tree deploys automatically and the Windsurf bridge runs once. Concretely:

1. **Bootstrap chezmoi** (first time only): `brew install chezmoi && chezmoi init --apply uhop`. This deploys everything, including `~/.claude/skills/` and the bridge.
2. **Or update an existing chezmoi machine**: `chezmoi update` (this runs `git pull` + `chezmoi apply` in one shot — never run them separately).
3. **Bridge runs once**: the first `chezmoi apply` after a clean clone runs `run_once_after_link-windsurf-skills.sh` automatically. After it succeeds, chezmoi remembers and won't re-run it.

Verify on the target machine:

```bash
ls ~/.claude/skills/                       # should list shell-env, docs-review, wiki-conventions
ls -la ~/.codeium/windsurf/ | grep skills  # should show: skills -> /home/<user>/.claude/skills
diff ~/.claude/skills/shell-env/SKILL.md ~/.codeium/windsurf/skills/shell-env/SKILL.md
                                           # should print nothing (same file via both paths)
```

Then launch Claude Code in any directory and confirm the skills appear in the available-skills list (`shell-env`, `docs-review`, `wiki-conventions`).

## Adding a new skill

1. **Create the source directory** in the chezmoi tree:
   ```bash
   mkdir -p $(chezmoi source-path)/private_dot_claude/skills/<name>
   ```
2. **Write `SKILL.md`** with YAML frontmatter (`name`, `description`) and the skill body.
3. **Commit** (optional but recommended):
   ```bash
   cd $(chezmoi source-path)
   git add private_dot_claude/skills/<name>
   git commit -m "skills: add <name>"
   ```
4. **Apply locally**: `chezmoi apply ~/.claude` (or just `chezmoi apply`).
5. **Push** when ready, then on every other machine: `chezmoi update`.

The new skill is picked up by Claude Code on its next session start. Already-running sessions won't see it until they restart.

## The Windsurf bridge in detail

`run_once_after_link-windsurf-skills.sh` handles every edge case:

| State of `~/.codeium/windsurf/skills` on the target machine | What the script does |
|---|---|
| `~/.codeium/windsurf/` doesn't exist (Windsurf not installed) | No-op |
| Already a symlink to `~/.claude/skills/` | No-op (logs the existing link) |
| A symlink to *somewhere else* | Refuses, prints the mismatch |
| Doesn't exist yet | Creates the symlink |
| A real directory whose subdirs all exist in `~/.claude/skills/` | Backs up to `skills.pre-claude-bridge.bak`, then symlinks |
| A real directory with subdirs *not* present in `~/.claude/skills/` | **Refuses**, prints the unmirrored skill names, instructs the user to merge them into the chezmoi source first |

The "refuse on unmirrored content" path is important: if a Windsurf install has skills that haven't been migrated to the chezmoi source yet, the bridge won't silently lose them. The user (or an AI agent reading this doc) is told to copy the missing skills into `$(chezmoi source-path)/private_dot_claude/skills/<name>/`, commit, push, and re-run `chezmoi update`. The bridge then succeeds on the next try.

## The Cascade backslash gotcha

The `shell-env` SKILL.md documents this prominently and is worth repeating here for any agent reading this doc:

- **Claude Code's Bash tool**: both `command cp` and `\cp` work (verified `\ls`, `\mkdir -pv`, `\cp -f`).
- **Windsurf's Cascade command runner**: `\cp` and similar **hang forever** because the runner fails to detect command completion. Use `command cp`.
- **Universal**: `command cmd` is POSIX-standard and works in every tool runner.

When in doubt — or when writing scripts/instructions that will be executed under either tool — use `command cmd`.

## Manual bootstrap fallback (no chezmoi)

If you're on a machine where chezmoi isn't installed and you need skills available *now*:

```bash
# 1. Create the canonical Claude skills directory.
mkdir -p ~/.claude/skills

# 2. Copy or symlink each skill from the dotfiles repo (or another source).
#    Example: clone the dotfiles repo somewhere temporary, then:
for s in shell-env docs-review wiki-conventions; do
  cp -r /path/to/dotfiles/private_dot_claude/skills/$s ~/.claude/skills/
done

# 3. (Optional) Bridge Windsurf if installed:
if [ -d ~/.codeium/windsurf ] && [ ! -e ~/.codeium/windsurf/skills ]; then
  ln -s ~/.claude/skills ~/.codeium/windsurf/skills
fi
```

This is a temporary setup. The proper fix is to install chezmoi and run `chezmoi init --apply uhop` so skills (and everything else) become managed.

## Files in this repo

- `private_dot_claude/skills/<name>/SKILL.md` — the actual skill files (the source of truth).
- `private_dot_claude/settings.json` — Claude Code user-level settings (`enabledPlugins`, `effortLevel`).
- `run_once_after_link-windsurf-skills.sh` — bridge script, runs after `chezmoi apply` once per machine.
- `.chezmoiignore` — excludes the project-local `.claude/settings.local.json` from deployment (it's a Claude Code permission cache for *this* repo, not global config).
- `dev-docs/ai-skills.md` — this file.
