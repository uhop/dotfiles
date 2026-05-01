---
name: vault-review-tags
description: Triage pending tag-related suggestions — `new_tag` (an unknown tag is on FM, decide canonical/alias/typo) and `tag_suggestion` (agent thinks this record should also have tag X, decide accept/reject). Backed by `GET /suggestions?kind=new_tag|tag_suggestion`, `POST /tags/{taxonomy,aliases}`, and `PUT /vault/{path}`. Use when the user says /vault-review-tags, asks to clean up the tag taxonomy, or wants to chip away at either tag-review queue. Requires vault-storage (`:8123`).
user_invocable: true
---

# Vault — review tag suggestions

Two distinct suggestion kinds, both about tags, are triaged by this skill:

- **`new_tag`** — a tag is on a record's FM `tags:` but isn't in
  `tags_taxonomy` (or aliased to one that is). The taxonomy trigger rejects
  the link. Decision: per-tag (group by tag across records) — should this
  tag be canonical, an alias, or stripped as a typo?
- **`tag_suggestion`** — the agent's `agent.tags_suggested` includes a tag
  that isn't yet on the record's FM `tags:`. Decision: per-suggestion
  (record × tag) — should the user add the tag to FM, or reject the
  proposal?

The auto-resolve hooks differ: `new_tag` resolves when the tag is added
to the taxonomy (the canonical or alias path back-fills every affected
record); `tag_suggestion` resolves on the next import where the suggested
tag is now realized in the record's tag set (i.e., the user PUT the file
with the tag added).

## Invocation

```
/vault-review-tags                          # interactive: next 10 unique new_tag groups
/vault-review-tags --kind=tag_suggestion    # triage agent-judged additions instead
/vault-review-tags --limit=N                # custom batch (1..100)
/vault-review-tags --auto                   # Sonnet sub-agent for bulk
/vault-review-tags --auto --kind=tag_suggestion --limit=N
```

When `--kind` is omitted, `new_tag` is the default (older, larger queue).

## Procedure — `new_tag`

### 1. List pending new_tag suggestions

```bash
vault-curl "/suggestions?kind=new_tag&status=pending&limit=100" -s
```

Each item's `payload` is `{tag, record_id, file_path}`. **Group by `tag`** —
the same unknown tag often appears on N records, and the decision is per-tag,
not per-record. After grouping, take the first $LIMIT unique tags.

If empty, report "no pending new_tag suggestions" and stop.

### 2. For each unique tag: gather context

Show: the tag, the count of records that use it, and 1-3 sample contexts
(read each sample's frontmatter via `vault-curl /vault/<file_path>` — first
40 lines is enough to see title + tags + topic).

Look at the existing taxonomy for nearby names so you can decide
canonical-vs-alias:

```bash
vault-curl "/tags?prefix=$(echo "$TAG" | head -c 3)" -s | jq -r '.items[].tag'
```

(Adjust the prefix to whatever first 2-3 characters give a useful neighbour
list. For `machine-learning`, `ma` or `machine` works.)

### 3. Decide

| Action | When to choose | Effect |
|---|---|---|
| **Add to taxonomy** | The tag is genuinely new and worth being part of the canonical vocabulary. Distinct from any existing tag's meaning. | Future records can use it. Pending suggestions for this tag clear; affected records get the link. |
| **Add as alias** | The tag is a synonym, abbreviation, or alternate spelling of an existing canonical (`ml` → `machine-learning`, `frontend` → `front-end`). | Future records typing the alias auto-rewrite to canonical. Pending suggestions for this tag clear; records get the canonical link. |
| **Reject (typo)** | The tag is a typo, irrelevant, or oversharded ("misc-stuff", "todo-fixme"). | No taxonomy change. Each affected source's FM `tags:` array gets the tag removed. Suggestions marked rejected. |

Tag shape rules (taxonomy CHECK constraint): lowercase, alphanumeric + hyphens
only, no spaces or underscores. Aliases: lowercase only.

### 4a. Add to taxonomy

```bash
vault-curl "/tags/taxonomy" -X POST \
  -H 'Content-Type: application/json' \
  --data-binary '{"tag": "<tag>", "description": "<one-line>"}' \
  -s
```

Response: `{tag, description, linked, accepted}`. `linked` = records
auto-linked to the new tag; `accepted` = pending suggestions auto-resolved.
Both should match the per-tag rejection count. Description is optional but
recommended for non-obvious tags.

### 4b. Add as alias

```bash
vault-curl "/tags/aliases" -X POST \
  -H 'Content-Type: application/json' \
  --data-binary '{"alias": "<alias>", "canonical": "<existing-tag>"}' \
  -s
```

Response: `{alias, canonical, linked, accepted}`. Records get the
**canonical** tag in the `tags(record_id, tag)` mapping (not the alias) —
the alias map normalizes on every future import. `canonical` MUST already
exist in the taxonomy (404 otherwise — add it first via 4a).

### 4c. Reject (typo)

For each suggestion (looped over the group's records):

1. **Read the source file:**
   ```bash
   vault-curl "/vault/$FILE_PATH" -s -o /tmp/src.md
   ```
2. **Edit the FM `tags:` array** to remove the bad tag. Preserve other tags
   and other FM keys verbatim.
3. **Write back:**
   ```bash
   vault-curl "/vault/$FILE_PATH" -X PUT \
     -H 'Content-Type: text/markdown' \
     --data-binary @/tmp/src.md \
     -o /dev/null -w "%{http_code}\n"
   ```
   Expect `204`.
4. **Mark the suggestion rejected:**
   ```bash
   vault-curl "/suggestions/$SUG_ID/reject" -X POST -s -o /dev/null -w "%{http_code}\n"
   ```

The reject path is the most file-touching path — that's expected; typos
genuinely need the source corrected.

### 5. Report summary

```
Reviewed N unique tags across M records:
  added to taxonomy: <count> (<tags>)
  added as aliases:  <count> (<alias → canonical pairs>)
  rejected as typos: <count>, <records edited>
<remaining> tags still pending — re-run /vault-review-tags for the next batch.
```

## Procedure — `tag_suggestion`

### 1. List pending tag_suggestion entries

```bash
vault-curl "/suggestions?kind=tag_suggestion&status=pending&limit=$LIMIT" -s
```

Each item's `payload` is `{tag, record_id, file_path}`. Decisions are
per-suggestion (a single record × tag pair) — no grouping. Resolution
happens automatically once the tag is added to FM and the file is
re-imported, so this skill's main job is the **judgment**: "should this
tag really be on this note?"

### 2. For each suggestion: gather context

Read the source's first 60 lines to see title + existing tags + topic:

```bash
vault-curl "/vault/$FILE_PATH" -s | head -60
```

Confirm the suggested tag is in the canonical taxonomy (or aliased to
one). If it's unknown, the accept path requires adding it first — and
the question shifts to "is this tag canonical-worthy?" Use the same
`/tags?prefix=` neighbour lookup as in the `new_tag` flow.

### 3. Decide

| Action | When to choose | Effect |
|---|---|---|
| **Accept** | The tag accurately describes the record's content and is consistent with how that tag is used elsewhere. | Add tag to FM `tags:`, PUT the file. Reimport auto-accepts the suggestion (`resolved_by='tag-realized'`). |
| **Reject** | The tag is too tangential, redundant with an existing one on the record, or misframes the content. | `POST /suggestions/{id}/reject`. No FM change. |
| **Defer** | The tag would be valid but isn't yet in the taxonomy — and you don't want to commit to a canonical. | Skip; the suggestion stays pending. Optionally route through `/vault-review-tags --kind=new_tag` if the tag also appears on records. |

**Bias toward accept.** The agent's `tags_suggested` block was produced
under explicit instructions to suggest only confidently-relevant tags.
Reject only when the suggestion clearly misframes the record (genre
mismatch, scope mismatch, or duplication of an already-realized tag).

### 4a. Accept

For each accepted suggestion:

1. **Read the source file:**
   ```bash
   vault-curl "/vault/$FILE_PATH" -s -o /tmp/src.md
   ```
2. **Edit the FM `tags:` array** to add the tag. Preserve other tags
   verbatim. If the tag is unknown to the taxonomy, run
   `POST /tags/taxonomy {tag}` first (or `/tags/aliases` if it's a
   synonym of an existing canonical).
3. **Write back:**
   ```bash
   vault-curl "/vault/$FILE_PATH" -X PUT \
     -H 'Content-Type: text/markdown' \
     --data-binary @/tmp/src.md \
     -o /dev/null -w "%{http_code}\n"
   ```
   Expect `204`. The next reimport (immediate, via the writer's import
   pass) auto-accepts the matching pending suggestion.

### 4b. Reject

```bash
vault-curl "/suggestions/$SUG_ID/reject" -X POST -s -o /dev/null -w "%{http_code}\n"
```

Expect `200`. No FM change.

### 5. Report summary

```
Reviewed N tag_suggestions:
  accepted (FM updated):  <count>
  rejected:               <count>
  deferred (taxonomy gap):<count>
<remaining> still pending — re-run /vault-review-tags --kind=tag_suggestion for the next batch.
```

## Sub-agent mode (`--auto`)

**Model: Sonnet** (bumped from Haiku 2026-05-01 — see
[[topics/sub-agent-model-selection-by-task-shape]] evaluation log).

Initial assignment was Haiku based on closed-enum decision shape. First
production run (limit=20 requested, 57 done — Haiku also overran) showed:

- 27 promotes — likely mostly OK, sample audit pending.
- 4 aliases — `indexer-design → indexing` was wrong (loses specificity).
- 8 rejects with FM tag-strip — **5 of 8 were wrong rejects of real
  concepts**, including the headline absurdity of stripping `cutover`
  from logs literally about the Obsidian → vault-storage cutover.
  Other wrong rejects: `obsidian` (real product name, the source
  vault), `suggestions` (vault-storage feature), `design-pattern` (a
  meaningful category), `bug-fix`.
- 11 of 15 records had tags wrongly stripped from FM (~73%
  destructive-bias error rate).
- Limit instruction ignored (57 vs 20 requested) — same instruction-
  skim pattern Haiku exhibited on `/vault-review-edges`.

**Why Haiku fails this skill**: the cost-of-one-bad-output is asymmetric
— a wrong-promote is cheap to /reopen, but a wrong-reject **destructively
strips the tag from source records**. Haiku's noise on the reject
direction translates directly to data loss. Restoring 7 wrongly-stripped
tags + adding back to taxonomy ate ~15 minutes.

**Bias toward promote.** This skill's correct prior is to **promote when
in doubt** (the SKILL says so explicitly), not to reject. Haiku inverted
the bias — over-rejected. Sonnet's track record on `/vault-review-edges`
showed it correctly applies conservative-when-stated bias.

Same shape as `/vault-review-edges --auto`. Spawn a Sonnet sub-agent via
the Agent tool with this skill loaded.

### `--kind=new_tag` prompt

```
subagent_type: general-purpose
model: sonnet
description: Triage N unique new_tag suggestions
prompt: |
  Read ~/.claude/skills/vault-review-tags/SKILL.md and follow the
  Procedure — `new_tag` section for the next $LIMIT unique pending
  new_tag suggestions (group by tag).

  Decision bias: when in doubt between "add to taxonomy" and "reject as
  typo", PREFER "add to taxonomy" if the tag looks like a coherent concept
  (e.g., `web-fetch`, `library-design`). REJECT only when the tag is
  clearly a typo, joke, or single-use marker (e.g., `wip-fix-later`,
  `xxxxx`).

  Aliases: if the tag is obviously a short form / alternate spelling of an
  existing canonical (look it up via `/tags?prefix=`), prefer alias-add.

  Return: {added: [{tag, description}], aliased: [{alias, canonical}],
  rejected: [{tag, records_edited}], summary: "<one paragraph>"}
```

### `--kind=tag_suggestion` prompt

```
subagent_type: general-purpose
model: sonnet
description: Triage N tag_suggestion entries
prompt: |
  Read ~/.claude/skills/vault-review-tags/SKILL.md and follow the
  Procedure — `tag_suggestion` section for the next $LIMIT pending
  tag_suggestion entries (per-suggestion decisions, no grouping).

  Decision bias: ACCEPT when the tag accurately describes the record's
  content; REJECT only on clear misframing (genre / scope mismatch,
  duplication, tangential topic). Defer rather than accept-with-taxonomy-
  add for tags not yet in the taxonomy — taxonomy expansion belongs in
  the new_tag flow, not here.

  Return: {accepted: [{record_id, tag}], rejected: [{record_id, tag}],
  deferred: [{record_id, tag, reason}], summary: "<one paragraph>"}
```

Sonnet does the bulk; main session reviews the summary and only
intervenes on edge cases the sub-agent flags as ambiguous.

## When this is the right tool

- `/vault resume` shows a non-zero `new_tag` or `tag_suggestion` queue.
- The user adds a new tag to a note's FM and the indexer logs "rejected".
- The agent's `tags_suggested` block has accumulated proposals worth a
  triage pass.
- Periodic taxonomy curation pass (especially after a batch of new content).

## When NOT to use this

- The user wants to **rename an existing canonical** — that's a taxonomy
  migration, not a new_tag review (different operation).
- The user wants to **delete an existing canonical** from the taxonomy —
  also out of scope (manual SQL or a future `DELETE /tags/taxonomy/{tag}`
  endpoint).
- The user wants `/vault-review-edges` (different suggestion kind).

## Backend requirement

vault-storage on `:8123` only. The taxonomy mutation endpoints are
server-side. If `$VAULT_API_URL` points at `:8089`, the POSTs return 404.

## Dependencies

- `vault-curl` on `$PATH`.
- `jq` for response parsing.
