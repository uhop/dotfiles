---
name: vault-enrich-all
description: "Generate or refresh agent-derived frontmatter enrichment (summary, key_concepts, tags_suggested, related_proposed, edge_classifications, complexity) for vault notes. Writes a namespaced `agent:` block per note that the indexer / chunker / embedder will consume for HyDE-style retrieval augmentation. Use when the user says /vault-enrich-all, asks to backfill summaries / concept tags, or wants to densify the agent-derived metadata layer. Per design `[[projects/vault-storage/design/agent-frontmatter-enrichment]]` — refines C12 by separating user-authored top-level frontmatter from agent-authored enrichment."
user_invocable: true
---

# Vault — agent-driven frontmatter enrichment

For each vault note, generate a namespaced `agent:` block in the
frontmatter that captures LLM-derived enrichment: a 1-2 sentence summary,
3-5 key concepts, tag/related-link proposals, edge-type classifications
for body wikilinks, and a complexity label. Hash-gated invalidation
ensures the block stays fresh on body changes.

The block lives in the source markdown file (constraint C4: file is
source of truth). It survives DB rebuilds, is git-tracked, and is
human-visible. The indexer / chunker / embedder consume `agent.summary`
as a HyDE-style prefix at index time per
`[[projects/vault-storage/design/embedding-model]]`.

## Invocation

```
/vault-enrich-all                       # default: review & enrich next 30 unenriched permanent notes
/vault-enrich-all --limit=N             # custom batch (1..200)
/vault-enrich-all --stale               # refresh stale blocks (hash mismatch) instead of new
/vault-enrich-all --type=log            # restrict to one record type (default: permanent)
/vault-enrich-all --auto                # spawn a Haiku sub-agent for bulk
/vault-enrich-all --auto --limit=N      # bulk + cap
```

## Per-note `agent:` block shape

```yaml
agent:
  derived_at: 2026-04-30T22:00:00Z
  derived_from_hash: <body content_hash, hex>
  summary: "<1-2 sentences capturing the note's core claim and scope>"
  key_concepts: [concept-1, concept-2, concept-3]
  tags_suggested: [proposed-tag-1, proposed-tag-2]   # candidates for top-level tags:
  related_proposed: ["[[other-note]]"]               # candidates for top-level related:
  edge_classifications:                              # body wikilinks → edge types
    "[[some-page]]": derived-from
    "[[other-page]]": applies-to
  complexity: prose      # one of: prose | code-heavy | tabular | mixed | hub | log-entry
```

Top-level user-authored frontmatter (`title`, `tags`, `related`, `status`,
`type`, `priority`, `edges`) is **not touched** — the agent only writes
inside its `agent:` namespace.

## Procedure

### 1. Pick the batch

Default: type=permanent (topic notes — densest expected enrichment value),
ordered by absence of `agent:` block (or by stale-hash if `--stale`):

```bash
vault-curl "/sections?type=permanent&limit=$LIMIT&exclude=body" -s | \
  jq -r '.items[] | "\(.record_id)\t\(.file_path)"'
```

For each candidate, fetch the file:

```bash
vault-curl "/vault/$FILE_PATH" -s -o /tmp/note.md
```

Parse the FM. If `agent.derived_from_hash` matches the record's current
content_hash (look it up via `/sections/{id}` or `vault_read_meta`), the
block is fresh — skip unless `--stale` is set.

### 2. Generate enrichment fields

Read the body. Reason about:

- **`summary`**: 1-2 sentences, ~40-80 words. Lead with the note's core
  claim or scope. Avoid restating the title verbatim. Concrete > abstract.
- **`key_concepts`**: 3-5 noun-phrases that the note hangs on. Lowercase,
  hyphen-separated. These are *concepts*, not necessarily tags — they may
  overlap with `tags_suggested` but serve a different purpose (retrieval
  anchors / dedup probes vs. taxonomy membership).
- **`tags_suggested`**: tags the agent thinks should join the top-level
  `tags:` array. Cross-reference the existing taxonomy:
  ```bash
  vault-curl "/tags?prefix=$(echo $CONCEPT | head -c 3)" -s
  ```
  Only suggest tags that already exist in the taxonomy OR are clearly
  worth adding. Don't propose freeform tags that would just become typos.
- **`related_proposed`**: wikilinks to other notes the agent thinks should
  join `related:`. Use `/sections/{id}/similar?k=15` for candidates;
  filter to those at distance ≤ 0.30; judge each.
- **`edge_classifications`**: for each `[[wikilink]]` in the body, propose
  an edge type from the canonical 10 (`derived-from`, `applies-to`,
  `cites`, etc.). The classifier's heuristic default is `cites`; this
  field is the agent's better classification. **The body-wikilink
  classifier and FM `edges:` map are still the runtime source of truth**
  (per `/vault-review-edges`); `edge_classifications` is a hint that the
  edge-review skill can leverage.
- **`complexity`**: one of `prose`, `code-heavy`, `tabular`, `mixed`,
  `hub` (a note that's mostly wikilinks to other notes), `log-entry`.

### 3. Write the block

Read existing FM, merge in or replace the `agent:` block:

```yaml
---
title: ...
tags: [...]
created: ...
updated: ...
status: ...
type: ...
related: [...]
edges:
  some-target: derived-from
agent:
  derived_at: 2026-04-30T22:00:00Z
  derived_from_hash: <body content_hash>
  summary: "..."
  key_concepts: [...]
  tags_suggested: [...]
  related_proposed: [...]
  edge_classifications:
    "[[some-target]]": derived-from
  complexity: prose
---
<body unchanged>
```

Look up the body content_hash via `/sections/{id}` to populate
`derived_from_hash`. Use the current ISO 8601 UTC timestamp for
`derived_at`.

Write back:

```bash
vault-curl "/vault/$FILE_PATH" -X PUT \
  -H 'Content-Type: text/markdown' \
  --data-binary @/tmp/note.md \
  -o /dev/null -w "%{http_code}\n"
```

Expect `204`. The writer's shallow FM merge replaces the `agent:` map
wholesale, so include all the fields you want preserved in your write.

### 4. Report summary

```
Enriched N notes:
  new blocks:           <count>
  refreshed (stale):    <count>
  skipped (fresh):      <count>
  errors:               <count>
<remaining> still needing enrichment — re-run /vault-enrich-all for the next batch.
```

## Sub-agent mode (`--auto`)

Per-note enrichment is the canonical sub-agent task: each note is
independent, the work is mostly textual reasoning over a single source,
and quality is consistent at Haiku scale.

```
subagent_type: general-purpose
model: haiku
description: Enrich N vault notes with agent: blocks
prompt: |
  Read ~/.claude/skills/vault-enrich-all/SKILL.md and follow the procedure
  for the next $LIMIT notes (type=permanent preferred; skip notes with
  fresh `agent:` blocks unless --stale was passed).

  Quality bar:
  - summary: lead with the claim, not the title rephrased
  - key_concepts: real noun-phrases, not generic words
  - tags_suggested: only existing taxonomy tags, or genuinely new ones;
    skip if uncertain
  - related_proposed: distance ≤ 0.30 only; conservative on ambiguous
  - edge_classifications: only when keyword cues are present; skip otherwise

  Return: {enriched: N, skipped_fresh: M, errors: K, summary: "..."}
```

Per-note cost (~1500 in / 300 out tokens at Haiku rates) is fractions of a
cent. Backfilling all permanent notes is a few-dollar one-shot pass.

## When this is the right tool

- Backfilling enrichment after vault-storage deploy (one-shot).
- Refreshing notes after material body edits (`--stale`).
- Periodic densification of recent ingest output.

## Server-side integration (shipped)

As of vault-storage schema 5/6, the indexer fully consumes the `agent:`
block:

- **Schema**: `records.agent_summary` and `records.agent_derived_from_hash`
  columns store the parsed block. `JsonRecord` surfaces them in
  `/sections/{id}` responses.
- **Importer**: parses `agent.summary` and `agent.derived_from_hash` from
  FM. The hash is wrapped into `embedInputHash` so summary changes
  invalidate the chunk set the same way body edits do.
- **Chunker**: when `agent.summary` is set, prepends `${summary}\n\n` to
  every emitted chunk as a HyDE-style retrieval anchor.
- **`embedPending`**: joins `agent_summary` into the pending query and
  passes it to the chunker.
- **Staleness**: when `agent.derived_from_hash` diverges from the body's
  current hash, an `agent_enrichment_stale` suggestion is filed. Auto-
  resolves with `resolved_by='hash-matched'` when this skill's next pass
  refreshes the block.

So writing the `agent:` block here is a fully load-bearing index-time
input — not just durable FM the indexer treats as inert.

## Backend requirement

vault-storage on `:8123` is sufficient — Obsidian's REST API merges FM the
same way, but lacks the structured suggestion / similar / record_id
endpoints that the procedure relies on for candidate generation.

## Dependencies

- `vault-curl` on `$PATH`.
- `jq` for response parsing.
