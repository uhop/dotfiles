#!/usr/bin/env bash
# run_once_after_link-windsurf-skills.sh
#
# Bridge ~/.codeium/windsurf/skills/ → ~/.claude/skills/ so Windsurf and
# Claude Code share the same skill tree. The actual skill files live in
# the separate `claude-config` repo (~/Open/claude-config/skills/);
# `install.mjs` symlinks them into ~/.claude/skills/, and this script
# adds the second hop for Windsurf.
#
# Behavior matrix:
#   - ~/.claude/skills missing (claude-config not installed yet)
#                                                  → exit 1, chezmoi retries on next apply
#   - ~/.codeium/windsurf/ does not exist          → no-op (Windsurf not installed)
#   - ~/.codeium/windsurf/skills missing           → create symlink
#   - ~/.codeium/windsurf/skills already a symlink → verify it points at the right place
#   - ~/.codeium/windsurf/skills is a real dir AND
#     all its subdirs exist in ~/.claude/skills/   → back up + replace with symlink
#   - ~/.codeium/windsurf/skills has unmirrored
#     content                                       → refuse, list it, instruct manual merge
#                                                     into claude-config (never clobber
#                                                     unmirrored windsurf content)

set -euCo pipefail

claude_skills="$HOME/.claude/skills"
windsurf_dir="$HOME/.codeium/windsurf"
windsurf_skills="$windsurf_dir/skills"

# Claude side must exist. If claude-config hasn't been installed yet
# (~/Open/claude-config + install.mjs --apply), this is a hard error so
# chezmoi marks the run_once as failed and re-tries next apply.
if [ ! -d "$claude_skills" ]; then
  echo "skills bridge: $claude_skills not found." >&2
  echo "  Install claude-config first:" >&2
  echo "    git clone git@github.com:uhop/claude-config.git ~/Open/claude-config" >&2
  echo "    node ~/Open/claude-config/install.mjs --apply" >&2
  echo "  Then re-run 'chezmoi apply' to re-trigger this bridge." >&2
  exit 1
fi

# Windsurf not installed → nothing to bridge.
if [ ! -d "$windsurf_dir" ]; then
  echo "skills bridge: $windsurf_dir not present (Windsurf not installed); nothing to do"
  exit 0
fi

# Already a symlink — verify it points at the right place.
if [ -L "$windsurf_skills" ]; then
  current_target=$(readlink -f "$windsurf_skills" 2>/dev/null || true)
  expected_target=$(readlink -f "$claude_skills" 2>/dev/null || true)
  if [ "$current_target" = "$expected_target" ]; then
    echo "skills bridge: $windsurf_skills already symlinked to $claude_skills"
    exit 0
  fi
  echo "skills bridge: $windsurf_skills is a symlink to $current_target, expected $expected_target"
  echo "  refusing to overwrite an existing symlink with a different target"
  echo "  resolve manually, then re-run 'chezmoi apply'"
  exit 1
fi

# No windsurf skills dir at all → just create the symlink.
if [ ! -e "$windsurf_skills" ]; then
  ln -s "$claude_skills" "$windsurf_skills"
  echo "skills bridge: created $windsurf_skills → $claude_skills"
  exit 0
fi

# Real directory exists. Walk subdirs and check that each one is mirrored
# in ~/.claude/skills/. Any windsurf-only subdir blocks the bridge.
unmirrored=()
for entry in "$windsurf_skills"/*/; do
  [ -e "$entry" ] || continue  # empty glob guard
  name=$(basename "$entry")
  if [ ! -e "$claude_skills/$name" ]; then
    unmirrored+=("$name")
  fi
done

if [ ${#unmirrored[@]} -gt 0 ]; then
  echo "skills bridge: $windsurf_skills has skills not present in $claude_skills:" >&2
  for name in "${unmirrored[@]}"; do
    echo "  - $name" >&2
  done
  echo >&2
  echo "  Refusing to clobber unmirrored windsurf content." >&2
  echo "  To migrate them: copy each listed skill into" >&2
  echo "    ~/Open/claude-config/skills/<name>/" >&2
  echo "  commit + push, then run 'claude-config-update' on this machine" >&2
  echo "  (or wait for the next playbash-daily run)." >&2
  echo "  Re-run 'chezmoi apply' afterwards to re-trigger this bridge." >&2
  exit 1
fi

# All windsurf subdirs are mirrored. Safe to back up and replace.
backup="${windsurf_skills}.pre-claude-bridge.bak"
if [ -e "$backup" ]; then
  echo "skills bridge: backup path $backup already exists; aborting" >&2
  exit 1
fi
mv "$windsurf_skills" "$backup"
ln -s "$claude_skills" "$windsurf_skills"
echo "skills bridge: backed up $windsurf_skills → $backup"
echo "skills bridge: created $windsurf_skills → $claude_skills"
