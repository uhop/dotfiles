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
raw/               # unprocessed source material
topics/            # compiled wiki notes (1 concept = 1 note)
projects/          # per-project knowledge (subfolder per project)
  {project}/
    decisions.md   # architecture & design decisions
    learnings.md   # gotchas, patterns, what worked
    stack.md       # tech stack & dependencies
    queue.md       # outstanding work
    state.md       # baseline snapshot for vault-check-drift
queries/           # filed Q&A research outputs
logs/              # session logs
_index.md          # archived 2026-04-29 — kept for inbound wikilinks; do not update
```

Discovery is dynamic via the live API, not via a curated index file:

| Question | Tool |
| --- | --- |
| What topics exist? | `vault_list_folder("topics/")` |
| What projects? | `vault_list_folder("projects/")` |
| Recent logs / queries | `vault_list_pieces(type=log, updated_since=…)` |
| Find a note about X | `vault_search(X, mode=semantic)` |
| What links to / from X? | `vault_backlinks(X)` / `vault_neighborhood(X)` |
| Tag taxonomy | `vault_list_tags`, `vault_records_by_tag` |

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

Compile **ready** raw notes into the wiki. Drafts (no `ready: true`)
are skipped — the user is still iterating on them.

1. **Pull the ready list.** `vault-curl /maintenance/raw-inbox -s | jq`
   returns `{ready: [...], drafts: [...]}`. Process only `ready`. If
   that array is empty, report "no ready notes; N drafts waiting" and
   stop. (The user flips `ready: true` in FM when a note is ripe.)
2. For each ready note, read the content via
   `vault-curl /vault/{path} -s`.
3. Extract concepts — create or update topic notes in `topics/`,
   project notes in `projects/<name>/`, or queue items in
   `projects/<name>/queue.md` per the content's nature.
4. Add wikilinks, backlinks, and tags on the derived notes.
5. **Enrich at capture.** When creating a new topic note (or materially
   rewriting an existing one), write the `agent:` block in the same PUT
   — born-enriched is cheaper than a later backfill pass through
   `/vault-enrich-all`. Field shape and quality guidance:
   `~/.claude/skills/vault-enrich-all/SKILL.md` § "Per-note `agent:`
   block shape" + § "Generate enrichment fields". Compute
   `derived_from_hash` locally as `sha256(body)` over the bytes you're
   about to write — no API round-trip needed, you own the body — and
   **double-quote the hash value** so YAML doesn't coerce all-digit
   hexes to integers. The indexer will pick the block up on import and
   fold the summary into the chunk-prefix at embed time.
6. **Archive the source.** After successful ingestion of a single raw
   note, in this order:
   - PUT the source with `ready` removed and `processed: true` added
     (and a `> Ingested YYYY-MM-DD → [[derived/note]]` footer pointing
     at the primary derived target if there is one).
   - `POST /vault/move` from `raw/<name>.md` to
     `raw/archive/<YYYY-MM-DD>-<name>.md` so the inbox surfaces only
     pending material.
   Process notes one-at-a-time end-to-end: derived note created →
   source updated → moved to archive. A failure mid-ingest leaves
   earlier notes archived and the rest still pending — safe to retry
   `/vault ingest` to resume.

### /vault learn

Extract learnings from the current project/session.

1. Identify the current project from git remote, directory name, or ask
2. Read existing project notes if they exist (`projects/{name}/`)
3. Analyze recent work: git log, changed files, decisions made
4. Create or update `projects/{name}/learnings.md`, `decisions.md`, `stack.md`
5. Extract cross-project patterns into `topics/` notes (e.g., "api-rate-limiting", "docker-networking"). When creating a new topic note here, enrich at capture per the `/vault ingest` step 5 procedure — write the `agent:` block in the same PUT.

### /vault query {question}

Research a question against the vault.

1. Use `vault_search` (or `POST /search/simple/`) to find candidate notes — try `mode=semantic` for conceptual queries, `mode=lexical` for verbatim phrases.
2. Read the most relevant notes (use `vault_neighborhood` or `vault_backlinks` to expand context if a single note isn't enough).
3. Synthesize an answer.
4. Optionally file the answer into `queries/YYYY-MM-DD-{slug}.md` if substantive — wikilinks back to the source notes used.

### /vault lint

Run the `vault-lint` skill to surface hygiene findings across the whole vault.

```bash
~/.claude/skills/vault-lint/vault-lint.sh           # full report
~/.claude/skills/vault-lint/vault-lint.sh --quiet   # data lines only
```

Categories reported: `FRONTMATTER` (required keys, date sanity), `WIKILINKS`
(broken targets), `DENSITY` (topic notes < 2 outbound; project notes orphaned),
`CURRENCY` (per-type retention thresholds — logs/queries/raw/project/permanent),
`DUPLICATES` (folders under `projects/` with confusingly-similar names).

Exit `0` clean, `1` if any findings. The skill at
`~/.claude/skills/vault-lint/SKILL.md` documents the rules; the policy lives
at `topics/vault-hygiene-policy.md` (in the vault) and is the source of truth
for thresholds.

Findings are reported only — auto-fix is not implemented. After running, decide:
- Fix legitimate issues directly (frontmatter backfill, broken-link rewrites).
- For per-type retention findings (e.g., logs > 90 days), move to
  `logs/archive/<YYYY>/` rather than delete; archival preserves content while
  removing it from the default `/vault resume` reading set.
- For duplicate-folder candidates, decide canonical and bulk-rewrite inbound
  wikilinks (the 2026-04-27 `tape6/` → `tape-six/` dedup is the procedural
  template — see `projects/tape-six/decisions.md` § Project name).

### /vault log {description}

Save a session log.

1. Create `logs/YYYY-MM-DD-{description}.md`
2. Record: what was done, decisions made, pending items, key files touched
3. Add wikilinks to relevant topic/project notes
4. **Refresh the drift baseline.** Run
   `~/.claude/skills/vault-check-drift/check-drift.sh --update` from the project
   directory so the next `/vault resume` starts from a clean baseline (the
   session's commits / tags / `npm publish` are typically done by the time
   you're logging). Bootstraps `state.md` if the project has no baseline yet.
   Skip only when there's no project working directory in scope (rare —
   logging cross-project work, vault-only sessions).

### /vault resume

Rebuild context from the vault.

1. **Drift check first.** Run `~/.claude/skills/vault-check-drift/check-drift.sh`
   from the current project directory (see the `vault-check-drift` skill for
   details). If drift is detected, surface the report at the top of the
   resume output before reading logs — the vault's view of the project may
   be stale, and the recorded logs reflect that stale view.
2. **Incremental reindex** — call `vault-curl /maintenance/incremental-reindex
   -X POST -s`. Brings the server's local DB in sync with the vault-data git
   tree if commits have landed since `last_indexed_commit` (typical case:
   another machine pushed and the local host pulled, or auto-commit ran
   while the watcher was off). The endpoint is fast and quiet on a
   no-op (`changedFiles: 0`); only surface output when something
   actually got reindexed, e.g.
   `Reindexed: 12 imported, 1 deleted, 0 renamed (a3525b1..be691da)`.
   On `fellBack: true`, mention the full-reindex path was taken (history
   loss or first run). Lint and suggestion-summary that follow this
   step now run against the up-to-date DB.
3. **Integrity lint** — call `vault_lint` (or `vault-curl /system/lint -s`).
   Cheap (~50ms). If `ok=false`, surface the non-zero check categories at
   the top of the resume output (with counts and the first sample id per
   category). These are bug indicators in the data — embedding drift,
   missing embeddings, orphaned chunks, temporal anomalies, dangling tag
   aliases. Do not auto-fix; report and let the user decide. If `ok=true`,
   omit lint from the output entirely.
4. **Review-queue summary** — call `vault_suggestions_summary` (or
   `vault-curl /suggestions/summary -s`). One-shot per-kind pending counts.
   If `total > 0`, surface a one-line summary like
   `Pending suggestions: 1290 edge_type, 50 duplicate, 44 new_tag (total 1384)`
   so the agent can decide whether to spend a triage block this session.
   If `total == 0`, omit. Don't auto-triage; the dedicated review skills
   (`/vault-review-edges`, `/vault-review-duplicates`, `/vault-review-tags`)
   handle decisions.
5. Read the 3 most recent session logs in `logs/`.
6. Read relevant project notes for the current working directory.
7. Summarize current state and what's left to do. If `check-drift` flagged
   new commits / tags / publishes that aren't reflected in `projects/<name>`
   notes, update those notes to match (or at minimum flag the divergence in
   the summary).
8. After syncing, run `check-drift --update` so the baseline captures the
   refreshed view and the next resume starts from a clean slate.

### /vault wrap [optional log slug]

Close the session cleanly — symmetric counterpart to `/vault resume`. Bundles
learning extraction, session log, and drift baseline refresh into one step so
nothing the session produced gets lost.

1. Run the `/vault learn` workflow above — extract learnings into
   `projects/{name}/{learnings,decisions,stack}.md` and surface cross-project
   patterns into `topics/` notes.
2. Run the `/vault log` workflow above with the supplied slug (or derive one
   from the session's primary subject if the user didn't supply it). Step 4 of
   `/vault log` refreshes the drift baseline as its closing action — no
   separate `check-drift --update` invocation needed here.
3. Report a short summary of what was saved: project notes touched, log file
   path, baseline refreshed.

Use this when ending a session that produced shipped work, decisions, or
cross-project learnings worth preserving. Skip when a session ends with
nothing worth preserving — don't write stub logs to be ceremonial.

### /vault check [--update]

Run the drift check standalone. Typically used mid-session to re-sync
after a user-driven commit, push, or publish.

```bash
~/.claude/skills/vault-check-drift/check-drift.sh            # report only
~/.claude/skills/vault-check-drift/check-drift.sh --update   # report + refresh baseline
```

The skill file at `~/.claude/skills/vault-check-drift/SKILL.md` documents
the signal sources, baseline file format, and report shape.

In multi-writer setups (the host pulls vault-data from a remote that
another machine pushed to), follow the project drift check with an
incremental reindex so the local DB catches up to the new HEAD:

```bash
vault-curl /maintenance/incremental-reindex -X POST -s | jq
```

Skip when working solo or when no `git pull` has happened recently —
the watcher already kept the DB in sync with local edits. A no-op call
is fast (a few ms) but unnecessary. The endpoint reports
`{fromCommit, toCommit, changedFiles, imported, deleted, renamed,
fellBack, durationMs}`; surface anything non-zero, otherwise stay
quiet.

### /vault (no subcommand)

Show vault status: note counts per folder, recently updated notes, any lint warnings.

## Proactive behavior

This skill should be used proactively when:
- The user discovers a non-obvious pattern, gotcha, or decision worth preserving
- A debugging session reveals something that would save time in the future
- Cross-project knowledge is generated (e.g., "this Docker networking trick works everywhere")
- The user says "remember this", "save this", "note this down"

When in doubt, ask: "Want me to save this to the vault?"
