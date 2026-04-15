---
name: vault
description: "Read and write to the Obsidian knowledge base vault. Use when the user says /vault, asks to remember/save knowledge, wants to recall/query stored knowledge, asks to extract learnings from a project, or wants to log a session. Also use proactively at session end to capture non-obvious learnings."
user_invocable: true
---

# Obsidian Knowledge Base

Persistent knowledge base in an Obsidian vault, accessed via REST API. The LLM writes and maintains all content — the user views it in Obsidian.

## Connection

Requires two environment variables (set in `~/.env`, which is sourced by `.bashrc`):

- `VAULT_API_URL` — base URL of the Obsidian Local REST API (e.g., `http://host:8089`)
- `VAULT_API_TOKEN` — bearer token for authentication

### Use `vault-curl` — don't hand-roll `curl`

There is a `vault-curl` wrapper on `$PATH` (installed under `~/.local/bin/vault-curl`). **Prefer it over raw `curl`** — it prepends `$VAULT_API_URL` and the `Authorization: Bearer $VAULT_API_TOKEN` header, checks the env vars, and forwards every remaining flag straight to `curl`.

Quick check before the first vault op in a session:

```bash
command -v vault-curl >/dev/null || { echo "vault-curl missing — falling back to curl"; }
```

`vault-curl` itself exits with a clear error if `VAULT_API_URL` or `VAULT_API_TOKEN` is unset, so no separate guard is required. Only fall back to raw `curl` if `vault-curl` isn't installed on the machine.

API endpoints (invoked via `vault-curl <path> [curl-options...]`):

- **Read**: `vault-curl /vault/{path} -s`
- **Write**: `vault-curl /vault/{path} -X PUT -H 'Content-Type: text/markdown' --data-binary @file.md`
  - Or with a heredoc: `vault-curl /vault/{path} -X PUT -H 'Content-Type: text/markdown' --data-binary @- <<'EOF' ... EOF`
  - Add `-o /dev/null -w "%{http_code}\n"` to confirm a 204 without flooding stdout.
- **List**: `vault-curl /vault/{path}/ -s` (trailing slash → `{"files": [...]}`)
- **Delete**: `vault-curl /vault/{path} -X DELETE`
- **Search**: `vault-curl /search/simple/ -X POST -G --data-urlencode 'query=...'`
  - The Obsidian Local REST API expects `query` as a URL parameter on a POST; `-G --data-urlencode` produces the right form.

### Fallback: raw `curl`

If `vault-curl` is unavailable, verify env vars explicitly:

```bash
[[ -z "${VAULT_API_URL:-}" || -z "${VAULT_API_TOKEN:-}" ]] && { echo "Error: VAULT_API_URL and VAULT_API_TOKEN must be set in ~/.env"; exit 1; }
```

Then use `curl -H "Authorization: Bearer $VAULT_API_TOKEN" "$VAULT_API_URL/<path>"` with the same endpoints listed above.

## Vault structure

```
_index.md          # master TOC — read this first to orient
raw/               # unprocessed source material
topics/            # compiled wiki notes (1 concept = 1 note)
projects/          # per-project knowledge (subfolder per project)
  {project}/
    decisions.md   # architecture & design decisions
    learnings.md   # gotchas, patterns, what worked
    stack.md       # tech stack & dependencies
queries/           # filed Q&A research outputs
logs/              # session logs
```

## Note format

Every note MUST have YAML frontmatter:

```yaml
---
title: Note Title
tags: [topic1, topic2]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
type: permanent | fleeting | project | query | log
related: ["[[other-note]]"]
---
```

Rules:
- Filenames in kebab-case: `auth-flow.md`
- Use wikilinks: `[[note-name]]` (not markdown links) for internal references
- 1 concept per topic note (atomicity)
- Minimum 2 wikilinks per note (dense linking)
- Every note starts with a 1-2 sentence summary paragraph

## Commands

### /vault ingest

Compile raw content into the wiki.

1. List files in `raw/` that haven't been processed
2. For each, read the content
3. Extract concepts — create or update topic notes in `topics/`
4. Add wikilinks, backlinks, and tags
5. Update `_index.md` with new entries
6. Add a `processed: true` tag to the raw note's frontmatter

### /vault learn

Extract learnings from the current project/session.

1. Identify the current project from git remote, directory name, or ask
2. Read existing project notes if they exist (`projects/{name}/`)
3. Analyze recent work: git log, changed files, decisions made
4. Create or update `projects/{name}/learnings.md`, `decisions.md`, `stack.md`
5. Extract cross-project patterns into `topics/` notes (e.g., "api-rate-limiting", "docker-networking")
6. Update `_index.md`

### /vault query {question}

Research a question against the vault.

1. Read `_index.md` to find relevant topics
2. Use `POST /search/simple/` to search vault content
3. Read the most relevant notes
4. Synthesize an answer
5. Optionally file the answer into `queries/YYYY-MM-DD-{slug}.md` if substantive
6. Update `_index.md` if a new query was filed

### /vault lint

Health-check the wiki.

1. List all notes in `topics/` and `projects/`
2. Check for: missing frontmatter, orphan notes (no inbound links), stale dates, missing summaries, broken wikilinks
3. Report issues and fix what can be fixed automatically
4. Suggest new topics or connections based on content analysis

### /vault log {description}

Save a session log.

1. Create `logs/YYYY-MM-DD-{description}.md`
2. Record: what was done, decisions made, pending items, key files touched
3. Add wikilinks to relevant topic/project notes

### /vault resume

Rebuild context from the vault.

1. Read the 3 most recent session logs in `logs/`
2. Read relevant project notes for the current working directory
3. Summarize current state and what's left to do

### /vault (no subcommand)

Show vault status: note counts per folder, recently updated notes, any lint warnings.

## Updating _index.md

When adding/modifying notes, always update `_index.md`:
- Under `## Topics`: `- [[topic-name]] — one-line description`
- Under `## Projects`: `- [[projects/name/learnings]] — one-line description`
- Under `## Recent Queries`: `- [[queries/YYYY-MM-DD-slug]] — question asked` (keep last 10)

Read `_index.md` first, merge new entries, write back. Don't duplicate entries.

## Proactive behavior

This skill should be used proactively when:
- The user discovers a non-obvious pattern, gotcha, or decision worth preserving
- A debugging session reveals something that would save time in the future
- Cross-project knowledge is generated (e.g., "this Docker networking trick works everywhere")
- The user says "remember this", "save this", "note this down"

When in doubt, ask: "Want me to save this to the vault?"
