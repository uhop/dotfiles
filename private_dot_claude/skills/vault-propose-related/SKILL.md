---
name: vault-propose-related
description: "Propose missing `related:` entries for vault notes by reviewing semantic-NN candidates. Use when the user says /vault propose-related, asks to densify cross-references in the vault, or wants to expand `related:` arrays without reading every note manually. Per source note, fetches top-K embedding nearest neighbours, filters out existing related: + body wikilinks, judges which remaining candidates are genuine semantic matches, writes accepted proposals either to a review note (default, conservative) or directly into source FM (--apply mode)."
user_invocable: true
---

# Propose missing `related:` entries

The vault's hand-curated `related:` arrays are sparse — typically 1–3 entries
per note while many notes have 8–15 genuinely related neighbours. This skill
densifies the graph by combining vault-storage's BGE retrieval index (which
surfaces candidates cheaply) with agent judgment (which decides which
candidates are *meaningful* relationships).

By default the skill is **suggestion-only** — proposals are written into a
vault note (`queries/YYYY-MM-DD-related-proposals[-N].md`) for human review.
With `--apply`, accepted proposals are written directly into source notes'
frontmatter `related:` arrays. Both align with constraint C16's
agent-driven-suggestions model.

## Invocation

```
/vault-propose-related                       # interactive: propose for next 30 source notes, write to review note
/vault-propose-related --limit=N             # custom batch (1..200)
/vault-propose-related --apply               # write accepted proposals directly to source FM
/vault-propose-related --auto                # spawn a Haiku sub-agent for bulk
/vault-propose-related --auto --limit=N      # bulk + cap
```

## Procedure

### 1. Pick the batch of source notes

Walk records that are good candidates for densification: prefer `type: permanent`
(topic notes — densest expected linking) with a short or empty `related:` array.
Use `vault_list_pieces` or `/sections?type=permanent&sort=created` to enumerate.

Track which records have already been reviewed in prior batches by checking
`queries/*-related-proposals*.md` files. Skip already-reviewed records.

### 2. For each source note: fetch candidates

```bash
vault-curl "/sections/$RECORD_ID/similar?k=15" -s
```

Response: `{root_id, k, items: [{record_id, file_path, title, score, distance, ...}]}`.
Self is excluded. `distance` is cosine distance — lower = closer match.

The server returns top-K regardless of distance. Apply a distance cap:

| Cosine distance | Cosine similarity | Disposition |
|---|---|---|
| ≤ 0.20 | ≥ 0.80 | Accept by default; only skip if clearly homonymous or topically off |
| 0.20–0.25 | 0.75–0.80 | Default-accept on subject-overlap; skip if only superficially similar |
| 0.25–0.30 | 0.70–0.75 | Be selective; accept only with strong topical justification |
| > 0.30 | < 0.70 | **Filter out** — below the 99%-recall operating point per the embedding baseline |

The 0.30 cap is the **99%-recall threshold** on the curated `related:` set:
only 1% of real relationships fall above this cap. Tilt heavily toward recall
because false-negative cost (a real relationship that never gets proposed)
is unbounded; false-positive cost (you check, decide skip) is bounded.

### 3. Filter out already-known relationships

Read the source note: `vault-curl "/vault/$FROM_PATH" -s`.

From the source's frontmatter and body, extract:
- `related:` array entries (existing wikilinks)
- Body wikilinks `[[...]]` (anything currently cited in prose)

For each candidate, resolve its `file_path` against the source's existing
known-targets. Drop candidates that match — those edges already exist in
some form. The `related:` array is the strict source of truth for typed
`related-to` edges; body wikilinks are weaker but still mean "the agent
already wrote this connection somewhere."

### 4. Judge each remaining candidate

For each candidate that survives the distance cap and the dedup filter:

- **Accept** if you would write this into the source's `related:` array
  based on a brief check of both notes' titles, tags, and topic. Heuristics:
  - Same project / same major topic area → almost certainly related
  - Subject overlap with clear semantic linkage → related
  - Same problem, different angle ("bash patterns" ↔ "specific bash gotcha") → related
  - Tangentially similar (both technical, no direct connection) → skip
  - Same word in title but different meaning (homonym) → skip
- **Flag as ambiguous** if you can't decide quickly. Don't guess — flag for
  human review. The cost of a wrong "accept" is higher than a "skip" or
  "ambiguous."

When the candidate's title alone is ambiguous, fetch the candidate's note
briefly: `vault-curl "/vault/$CANDIDATE_PATH" -s | head -40`. Read sparingly —
the goal is a fast batch pass, not exhaustive verification.

### 5a. Default mode: write proposals to a review note

Save to the vault as `queries/YYYY-MM-DD-related-proposals[-N].md` (use a
sequence suffix if multiple batches in one day):

```yaml
---
title: Related-edge proposals — YYYY-MM-DD batch N
tags: [vault, related-proposals, query]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: pending-review
type: query
related: ["[[projects/vault-storage/queue]]", "[[projects/vault-storage/design/embedding-baseline]]"]
---
```

Body structure: one section per source note. For each, list accepted
proposals as wikilinks with a one-line rationale. Skipped candidates can be
omitted; flag any *ambiguous* ones in a "needs human verdict" section.

```markdown
## `<source-note-path>`

**Add to `related:`**:
- `[[<candidate-1>]]` — <one-line reason: e.g., "same project; covers the schema-decision side of <topic>">
- `[[<candidate-2>]]` — <reason>

**Ambiguous (human verdict needed)**:
- `[[<candidate-3>]]` — <why it's borderline>
```

Save with:

```bash
vault-curl "/vault/queries/$FILENAME" -X PUT -H 'Content-Type: text/markdown' --data-binary @- < /tmp/proposals.md
```

### 5b. Apply mode (`--apply`): write directly to source FM

For each source with accepted proposals:

1. **Read source content:** `vault-curl "/vault/$FROM_PATH" -s -o /tmp/src.md`
2. **Edit FM `related:`**: append accepted candidates as `"[[<target>]]"` strings,
   preserving existing entries.
3. **Write back:** `vault-curl "/vault/$FROM_PATH" -X PUT -H 'Content-Type: text/markdown' --data-binary @/tmp/src.md`

The writer's shallow FM merge replaces `related:` wholesale, so include all
existing entries plus your additions. Body unchanged.

Apply mode is faster but skips the human review step. Use it when:
- The user has explicitly asked for `--apply`
- Sub-agent confidence is high (cosine ≤ 0.20) — strong matches
- The user is actively reviewing the conversation (not background)

### 6. Report summary

```
Reviewed N source notes (R candidates considered, A accepted, S skipped, M ambiguous).
[Default mode]    Proposals written to queries/<filename>.md — review and reply 'apply'.
[Apply mode]      <X> source notes' related: arrays updated.
```

## Sub-agent mode (`--auto`)

**Model: Haiku** (default mode) **/ Sonnet** (`--apply` mode). Per
[[topics/sub-agent-model-selection-by-task-shape]]: default mode writes
proposals to a queries note for human review (low-stakes textual judgment
on candidate pairs — Haiku fits). `--apply` mode writes directly to the
source notes' FM `related:` arrays without human gate; that's structured
YAML output at scale plus higher cost-of-one-bad-output (a wrong-related
entry pollutes the typed-edge graph). Bump to Sonnet when applying.

```
subagent_type: general-purpose
model: haiku
description: Propose related: entries for N source notes
prompt: |
  Read ~/.claude/skills/vault-propose-related/SKILL.md and follow the
  procedure for the next $LIMIT source notes (type=permanent preferred).
  Default mode (write to queries note); be CONSERVATIVE on accepts —
  better to under-suggest. Flag anything you're <80% sure about as
  ambiguous rather than accepting.

  Return: {reviewed: N, accepted: A, ambiguous: M, proposals_path: "..."}
```

For `--auto --apply`, only use Haiku when the user has explicitly
authorized direct apply — this skips human review.

## Output discipline

- **Be conservative on accepts.** Better to under-suggest and let the user
  run another batch than to flood `related:` arrays with weak edges.
- **Don't auto-apply by default.** The skill's value is the agent judgment
  layer between brute-force retrieval and human curation; that layer is
  only trustworthy if its outputs go through human review (or are flagged
  as auto-applied).
- **Track which notes have been reviewed.** Subsequent batches should skip
  source notes already covered by prior `queries/*-related-proposals*.md`
  files. Cheap parse: read each prior proposals note's body, extract the
  `## <path>` headings.

## When NOT to use this skill

- **Per-query semantic search** — that's runtime via `/vault-search` /
  `vault_similar`, not this offline pass. This skill is for *enriching the
  curated edges*, run periodically (weekly / on-demand).
- **Typed-edge classification** (e.g., `supersedes`, `caused-by`) — those
  are agent-judged via `/vault-review-edges` after the indexer files
  `edge_type` suggestions. This skill produces `related-to` only, the
  loosest edge type (symmetric, auto-mirrored).

## Backend requirement

vault-storage on `:8123`. The `/sections/{id}/similar` endpoint relies on
the BGE embedding index, which Obsidian's REST API doesn't have. If
`$VAULT_API_URL` points at `:8089`, similar lookups return 404.

## Background

Why this works: BGE retrieval (chunked, CLS-pooled, see `[[projects/vault-storage/design/embedding-model]]`)
achieves ~24× lift over random for R@10 on the live vault. Absolute
precision is depressed by sparse curation — many "false positives" at high
cosine are *real* matches that nobody got around to writing into FM. This
skill captures them: agent judges which top-K candidates are genuine; the
curated set densifies; subsequent retrieval-quality evals improve.
