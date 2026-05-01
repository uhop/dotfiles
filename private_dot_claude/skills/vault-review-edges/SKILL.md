---
name: vault-review-edges
description: Triage pending `edge_type` suggestions in the vault — promote default `cites` body wikilinks to a more specific edge type (derived-from, applies-to, supersedes, etc.) by editing the source record's frontmatter `edges:` map, or confirm `cites` is correct and reject the suggestion. Backed by `GET /suggestions?kind=edge_type&status=pending` and the standard frontmatter writer. Use when the user says /vault-review-edges, asks to triage / clean up the typed-edge graph, or wants to chip away at the classifier's review queue. Requires vault-storage (`:8123`) — the suggestion-filing logic is server-side.
user_invocable: true
---

# Vault — review edge_type suggestions

The body-wikilink classifier auto-promotes keyword-cued links to typed edges
("derived from [[X]]" → `derived-from`) and defaults the rest to `cites`. Each
default-cites edge is filed as a pending `edge_type` suggestion. This skill
triages the queue: promote `cites` to a more specific type by writing the
source record's frontmatter `edges:` map, or accept `cites` as correct.

The decision lives in the source `.md` file (constraint C4: markdown is
source of truth). Reindex picks up the FM override and pins the edge type.
Pending suggestions auto-resolve to `accepted` with `resolved_by='fm-override'`
when the indexer sees a freshly-applied override — clean closure even if the
user edits FM manually.

## Invocation

```
/vault-review-edges                    # review the next batch (default 10)
/vault-review-edges --limit=N          # custom batch size (1..100)
/vault-review-edges --auto             # spawn a Haiku sub-agent to triage in bulk
/vault-review-edges --auto --limit=N   # bulk + cap
```

## Procedure

### 1. List pending suggestions

```bash
vault-curl "/suggestions?kind=edge_type&status=pending&limit=$LIMIT" -s
```

Response: `{items: [{id, subject_id, payload: {from_record, from_path, to_record, to_path, classifier_type, context}}, ...], total, ...}`.

If `items` is empty, report "no pending edge_type suggestions" and stop.
Otherwise tell the user: `<batch> of <total> pending. Reviewing now.`

### 2. For each suggestion: decide the type

Read the payload's `context` (~120 chars on each side of the wikilink). For
most cases that's enough to judge. When ambiguous, fetch source/target:

```bash
vault-curl "/sections/$FROM_RECORD" -s | jq -r '.body' | head -40
vault-curl "/sections/$TO_RECORD" -s | jq -r '.title, .body' | head -40
```

The 10 valid edge types (from `EDGE_TYPES` in the codebase):

| Type | When to choose |
|---|---|
| `cites` | Default; the source merely refers to the target. **No FM edit needed; just reject.** |
| `derived-from` | Source builds on / extends / is grounded in target. Strong intellectual debt. |
| `supersedes` | Source replaces / obsoletes / makes-obsolete the target. |
| `revises` | Source amends or refines target without replacing it. |
| `caused-by` | Source describes a state that target produced. |
| `fixed-by` | Source describes a problem that target resolves. |
| `rejected-because` | Source records a rejection whose reason is target. |
| `applies-to` | Source's content applies / is relevant to target's domain. |
| `contradicts` | Source disagrees with target. (Symmetric — auto-mirrors.) |
| `related-to` | Loose conceptual link. (Symmetric — auto-mirrors.) Prefer for the body wikilinks that don't fit anything more specific but are stronger than `cites`. |

Default-cites that fit nothing else: keep as cites (reject the suggestion).
Don't force a type just to clear the queue.

### 3a. Promote to a specific type — write FM `edges:` entry

Read the current source file:

```bash
vault-curl "/vault/$FROM_PATH" -s -o /tmp/src.md
```

Open `/tmp/src.md`. The frontmatter is the YAML block between the leading
`---` markers. Add (or extend) the `edges:` map:

```yaml
---
title: ...
edges:
  <target-as-written-in-body>: <chosen-type>   # NEW
  <existing-key>: <existing-type>              # PRESERVE if any
---
```

The target key must match the wikilink as written in the body (slug or path
form — `[[foo]]` → `foo`, `[[topics/foo]]` → `topics/foo`). The resolver
collapses both to the same record, but FM keys aren't deduplicated.

Write the modified file back:

```bash
vault-curl "/vault/$FROM_PATH" -X PUT \
  -H 'Content-Type: text/markdown' \
  --data-binary @/tmp/src.md \
  -o /dev/null -w "%{http_code}\n"
```

Expect `204`. The writer enforces FM merge rules; user-authored keys (like
`edges:`) are preserved.

Then mark the suggestion accepted:

```bash
vault-curl "/suggestions/$ID/accept" -X POST -s -o /dev/null -w "%{http_code}\n"
```

(The indexer's auto-accept-on-fm-override usually fires on the next reindex
anyway, but explicit accept ensures the queue clears immediately.)

### 3b. Confirm cites is correct — reject without FM edit

```bash
vault-curl "/suggestions/$ID/reject" -X POST -s -o /dev/null -w "%{http_code}\n"
```

No FM edit. The suggestion sits in `rejected` state forever; the filer's
idempotency check skips re-filing on next reindex. (Tradeoff: a full DB
rebuild from .md will re-suggest the pair. Acceptable for the volume.)

### 4. Report summary

```
Reviewed N suggestions: A promoted, R rejected, S still ambiguous (skipped).
M still pending in the queue — re-run /vault-review-edges for the next batch.
```

## Sub-agent mode (`--auto`)

**Model: Haiku.** Per
[[topics/sub-agent-model-selection-by-task-shape]] — output is a
closed-enum decision (one of 10 edge types or `reject`); cost-of-one-bad-
output is low (a wrong call is reversible via `/suggestions/{id}/reopen`);
the work is bulk triage with simple keyword cues. The 2026-04-30 wave
demonstrated good Haiku decision quality on the live backlog (10 in 125 s,
8 promoted / 2 rejected, conservative on ambiguous cases).

For bulk triage of an accumulated backlog, spawn a Haiku sub-agent via the
Agent tool. Pattern:

```
subagent_type: general-purpose
model: haiku
description: Triage N edge_type suggestions
prompt: |
  You are running /vault-review-edges in autonomous mode. Read
  ~/.claude/skills/vault-review-edges/SKILL.md and follow the procedure for
  the next $LIMIT pending suggestions. Default to `cites` (reject) when in
  doubt — don't force a more specific type without solid evidence in the
  payload context.

  Return: {accepted: N, rejected: M, skipped: K, summary: "<one paragraph>"}
```

Sub-agent uses the cheap model; main session sees only the summary. This
keeps token costs proportional to the *judgment* work, not the *paperwork*.

For obvious-cites links (the majority), Haiku will reject without further
context. For genuine candidates, Haiku may surface them as `skipped` for the
main session to decide — pass `skip_uncertain: true` in the prompt to enable
this.

## When this is the right tool

- The vault has accumulated default-cites edges that should be more specific.
- A `/vault resume` summary shows pending `edge_type` suggestions.
- The user asks to "clean up" or "triage" the typed-edge graph.

## When NOT to use this

- The user wants to **add** an edge that doesn't exist yet — that's done by
  editing the body to add a wikilink, not via this skill.
- The user wants to **remove** an edge — delete the wikilink from the body
  (or remove the FM `edges:` entry if it pinned a type).
- The user wants to triage *other* suggestion kinds (`tag_suggestion`,
  `duplicate`, etc.) — separate skills handle those (queued).

## Backend requirement

vault-storage on `:8123` only. Filing logic is server-side; Obsidian's
backend has no notion of edge_type suggestions. If `$VAULT_API_URL` points
at `:8089`, the listing endpoint returns 404 — flag the cutover state.

## Dependencies

- `vault-curl` on `$PATH`.
- `jq` for response parsing.
- The standard FM writer (`PUT /vault/{path}`) — handles merge semantics.
