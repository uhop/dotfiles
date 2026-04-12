# pick — interactive command reference

## Problem

~40+ aliases and helpers across git config, bash aliases, and scripts. Without
regular use, they're invisible — effectively dead code. Users shouldn't need to
memorize everything; they need a way to discover and run what's available.

## Solution

A small bash script (`pick`) that presents available commands by topic via fzf,
shows a doc line with options/arguments, lets the user edit the command, then
echoes and runs it.

### Entry points

| Entry | What it does |
|-------|--------------|
| `pick` | List available topics via fzf, then commands in the chosen topic |
| `pick git` | Jump straight to the git topic |
| `pick rsync` | Jump straight to the rsync topic |
| `git pick` | Same as `pick git` (via `git-pick` script) |
| `h` | Alias for `pick` (replaces the current `history` alias) |
| `h git` | Same as `pick git` |

### UX flow

```
$ pick git

  git br -a          All branches with subject, date, author
  git bs             Branches in table format (date, author, branch, subject)
  git del <branch>   Force-delete a branch
  git trim           Delete all local branches except main/master/current
  git tree           Full branch graph (all branches)
> git ls             Compact commit log (oneline, decorated)
                     git ll adds numstat, git lsf adds graph + follow
  6/28
  Snippets: ls

── doc ─────────────────────────────────
git ls [<revision range>] [-- <path>]

$ git ls             ← editable prompt, pre-filled with selected command
                       user appends flags/args and hits Enter
```

1. fzf shows commands with short descriptions (right side or inline).
2. A preview pane (or header) shows the doc: full argument spec, option
   descriptions, and any notes.
3. On selection:
   - Command with no typical arguments → echo and execute immediately.
   - Command that usually takes arguments → `read -e -i "cmd "` pre-filled
     prompt. User edits freely, hits Enter.
4. The executed command is echoed in color before running (same `echoRun`
   convention as existing aliases).

### Data format

JSON files, one per topic, in `~/.local/share/pick/`. Chezmoi-managed.

```json
[
  {
    "cmd": "git ls",
    "desc": "Compact commit log (oneline, decorated)",
    "doc": "git ll adds numstat, git lsf adds graph + follow",
    "args": true
  },
  {
    "cmd": "git br",
    "desc": "All branches with subject, date, author",
    "doc": "git brr for remote branches sorted by date",
    "args": true
  },
  {
    "cmd": "git trim",
    "desc": "Delete all local branches except main/master/current, prune origin",
    "args": false
  },
  {
    "cmd": "upd",
    "desc": "Update all package managers",
    "doc": "-c cleanup after, -y assume yes, -r restart docker on upgrade",
    "args": true
  }
]
```

Fields:

| Field | Required | Description |
|-------|----------|-------------|
| `cmd` | yes | The command as it would be typed |
| `desc` | yes | One-line description shown in fzf alongside the command |
| `doc` | no | Extended help shown in the preview pane: options, argument spec, notes |
| `args` | no | `true` = present editable prompt (default), `false` = execute immediately |

Why JSON:
- `jq` is already installed everywhere in this project.
- No specialized parser needed — bash + jq.
- Trivially convertible to TOML/YAML if ever needed.
- Easy to validate, lint, and generate.

### Script structure

`pick` is a single bash script at `~/.local/bin/pick`.

```
pick [topic]
```

- No args: list topics (derived from filenames in `~/.local/share/pick/*.json`),
  present via fzf, then show commands for the chosen topic.
- With topic arg: jump directly to that topic's commands.

Dependencies: `bash`, `jq`, `fzf`. All already installed.

`git-pick` is a one-liner script:

```bash
#!/usr/bin/env bash
exec pick git "$@"
```

### Topic files (v1)

**`git.json`** — git aliases, custom commands, shell aliases for git.
Subtopics via grouping in the file (log, branches, commits, reset, inspect).

**`rsync.json`** — rsync-based transfers (cpg, mvg, rcp, rmv, rup, rsy).
Demonstrates non-git topic separation.

### Alias changes

| Current | New |
|---------|-----|
| `h` = `history` | `h` = `pick` |

`history` is still available as the built-in. And Ctrl+R (fzf history search)
is the primary way to search history anyway.

### Relationship to pet

Complementary, not overlapping:

| | pet | pick |
|---|---|---|
| Content | Personal snippets | Curated dotfiles reference |
| Managed by | User (gist sync) | Chezmoi |
| Data | `~/.config/pet/snippet.toml` | `~/.local/share/pick/*.json` |
| UX | Exact commands, `<param>` placeholders, Ctrl+N | Commands with docs, freeform editing |
| Purpose | "I saved this once" | "What do I have available?" |

### Future topics (beyond v1)

- `system` — upd, cln, psg, oports, duf, free, etc.
- `docker` — dcm, dcms, lzd, docker prune, etc.
- `ssh` — ssht, mosht, ett, kssht, etc.
- `playbash` — run, push, exec, put, get, doctor, etc.
- `files` — cpg, mvg, rcp, rmv, gimme, where, upfind, etc.

Topics can be added incrementally — one JSON file each.

## Open questions

1. **fzf preview vs. header for docs?** Preview pane (right side) gives more
   room but may feel heavy for short docs. Header (top of fzf) is simpler.
   Could use `--preview` for entries with `doc`, header for topic name.
   → Start with preview pane, adjust based on feel.

2. **Grouping within a topic?** Git has ~30 entries spanning log, branches,
   commits, etc. Options: (a) flat list, rely on fzf search; (b) add a
   `group` field for visual separators in fzf output; (c) sub-topics like
   `pick git log`, `pick git branch`. → Start with (a), fzf search handles
   it well. Add (b) if it feels crowded.

3. **Completion for `pick` itself?** Tab-completing topic names is easy
   (list JSON filenames). Worth adding in v1.
