---
name: vault-review-duplicates
description: "Triage pending `duplicate` suggestions filed by vault-storage's pairwise vector-similarity scan. Decide per pair: confirm as duplicate (merge into one note, redirect wikilinks), accept as related-but-distinct (add `related:` entries on both notes), flag as contradiction (file a `contradiction_candidate`), or reject as a false positive. Backed by `GET /suggestions?kind=duplicate` + the standard frontmatter writer + `vault_delete_file`. Use when the user says /vault-review-duplicates, asks to triage near-duplicate notes, or wants to clean up the topical graph. Requires vault-storage (`:8123`)."
user_invocable: true
---

# Vault — review duplicate suggestions

vault-storage's `POST /maintenance/find-duplicates` scans embedded records
for high cosine similarity (default ≥ 0.90) and files a pending `duplicate`
suggestion per pair. This skill triages the queue. Outcomes are nuanced:
two near-duplicate notes might genuinely be redundant (merge), might be
distinct-but-related (add `related:` and reject), might contradict each
other (flag as `contradiction_candidate`), or might be a false positive
of the embedding model (reject).

The merge path is the only destructive one — it deletes one of the two
notes after combining content. **Default to non-destructive resolutions**
unless the agent has high confidence and the user has authorized direct
merges.

## Invocation

```
/vault-review-duplicates                    # interactive: review next batch (default 10)
/vault-review-duplicates --limit=N          # custom batch (1..100)
/vault-review-duplicates --auto             # spawn a Haiku sub-agent for bulk
/vault-review-duplicates --auto --limit=N   # bulk + cap
/vault-review-duplicates --scan             # run a fresh scan first (optional; pre-existing pairs aren't refiled)
/vault-review-duplicates --scan --max-distance=0.05  # tighter threshold for the scan
```

## Procedure

### 0. Optional: refresh the queue

```bash
vault-curl "/maintenance/find-duplicates?max_distance=0.10" -X POST -s
```

Response: `{scanned, skippedUnembedded, pairsFound, filed, durationMs}`.
Idempotent — won't refile pairs that already have a suggestion in any
status. Skip this step unless the user asked for `--scan` or the queue
looks stale.

### 1. List pending duplicate suggestions

```bash
vault-curl "/suggestions?kind=duplicate&status=pending&limit=$LIMIT" -s
```

Each item's payload: `{a_record, a_path, b_record, b_path, distance}`.
Distance is cosine: 0 = identical, 0.10 = strong match, 0.15 = topical
neighbour, > 0.30 = unrelated. Items returned by the scan are all under
the threshold; sort/group as needed.

If empty, report "no pending duplicate suggestions" and stop.

### 2. Per pair: read both notes for context

```bash
vault-curl "/vault/$A_PATH" -s
vault-curl "/vault/$B_PATH" -s
```

Read frontmatter (title, tags, status, type, created/updated dates) and at
least the first 40 lines of body. Look for:

- **Identical or near-identical content** (paragraph-level overlap) → merge candidate
- **Same topic, different angle / different audience** (one is a tutorial, one is a reference) → likely distinct, add `related:`
- **Same topic, contradicting conclusions** (one says "always do X", the other says "never do X") → contradiction
- **Different topics that happen to share vocabulary** (homonyms, vocabulary clash) → false positive

Pay attention to:
- Created dates: a much older note might be superseded by the newer one
- `status` field: `superseded` indicates one is already retired
- `type`: `log` vs `permanent` vs `query` — different lifecycles, usually not duplicates even if topically similar

### 3. Decide

| Action | When | Cost |
|---|---|---|
| **Reject (false positive)** | High cosine but actually distinct topics; vocabulary overlap; different lifecycles | Cheap — one POST |
| **Add related-to** | Same topic, distinct enough that both should exist | Two FM writes (one per note's `related:` array) + accept |
| **Flag as contradiction** | Both genuinely cover the same ground but reach different conclusions | One file_suggestion call (kind=`contradiction_candidate`) + reject the duplicate suggestion |
| **Merge (destructive)** | True duplicate: one note is the canonical version, the other's content is redundant or fits cleanly into the canonical. **High agent confidence required.** | Read both, write merged content into the canonical, delete the redundant, update inbound wikilinks if any |

Default bias: **reject or add-related**. Merging is irreversible without
git restore; only do it when the redundancy is unambiguous.

### 3a. Reject (false positive)

```bash
vault-curl "/suggestions/$ID/reject" -X POST -s -o /dev/null -w "%{http_code}\n"
```

No FM changes. The pair stays as-is. Future scans (with idempotency check)
won't refile.

### 3b. Add related-to to both notes

Two FM writes — one for each note's `related:` array. **Use the JSON
write path** (`Content-Type: application/json`) — it eliminates the
hand-composing-the-FM-block class of bugs that wiped 15 files on
2026-05-01 (a sub-agent's PUT-helper appended the original file's
content to a new FM block, producing a double-FM payload that destroyed
the body). With JSON you only send the keys you're updating; the
writer's shallow merge preserves everything else on disk verbatim.

**Safe recipe** for each of `$A_PATH` and `$B_PATH`:

```bash
# 1. Read the existing related list (omit body — meta-only fetch).
existing=$(vault-curl "/sections/$RECORD_ID/meta" -s | jq '.related // []')

# 2. Append the cross-link if not already present.
new_related=$(echo "$existing" | jq --arg link "[[$OTHER_PATH_NO_MD]]" 'if index($link) then . else . + [$link] end')

# 3. Read body once, pass through unchanged.
vault-curl "/vault/$NOTE_PATH" -s | awk '/^---$/{c++; next} c>=2{print}' > /tmp/body.md

# 4. Compose the JSON payload — only `related` is updated.
jq --null-input \
  --rawfile body /tmp/body.md \
  --argjson related "$new_related" \
  '{frontmatter: {related: $related}, body: $body}' \
  > /tmp/payload.json

# 5. PUT.
vault-curl "/vault/$NOTE_PATH" -X PUT \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/payload.json \
  -o /dev/null -w "%{http_code}\n"
```

Expect `204`. The double-FM-block hazard doesn't apply to the JSON path
— the request body is a JSON object, not a markdown blob with
`---\n…\n---` markers. (The malformed-double-frontmatter guard still
fires on the JSON path's `body` field if you accidentally include a
nested `---\n…\n---` opening at the start of the body string, but
that's much harder to trip into.)

After both notes have the cross-reference, accept the suggestion:

```bash
vault-curl "/suggestions/$ID/accept" -X POST -s -o /dev/null
```

The reindex picks up the new `related:` entries → `related-to` edges
auto-mirror; the pair becomes formally connected.

### 3c. Flag as contradiction

Currently no server-side endpoint exists for filing
`contradiction_candidate` suggestions directly (file via SQL or defer).
Pragmatic interim: **reject the duplicate suggestion with a note in the
agent's response** describing the contradiction; the user can flag for
manual review. (Future: add `POST /suggestions` with arbitrary kind for
agent-filed suggestions.)

### 3d. Merge (destructive — high confidence only)

**Get explicit user confirmation** before executing. Then:

1. **Choose canonical**: the note that should remain. Heuristics:
   - More recent `updated:` → likely the active version
   - More inbound wikilinks (run `vault-curl /sections/$ID/backlinks`) → more entrenched
   - More structured / well-titled / has wider tags → preferred home
   - When in doubt, prefer the older note (preserves history) and absorb the newer's unique content.
2. **Write merged content**: combine the canonical's content with anything unique from the redundant note. Edit FM `tags:` to union both notes' tags. Increment-style update — don't lose anything from either note.
3. **Update inbound wikilinks**: for each backlink to the redundant note, edit the source's body to point at the canonical. Run:
   ```bash
   vault-curl "/sections/$REDUNDANT_ID/backlinks" -s
   ```
   Then for each backlink source, read, search-replace the body, write back.
4. **Delete the redundant note**:
   ```bash
   vault-curl "/vault/$REDUNDANT_PATH" -X DELETE -s -o /dev/null -w "%{http_code}\n"
   ```
5. **Accept the suggestion**:
   ```bash
   vault-curl "/suggestions/$ID/accept" -X POST -s
   ```

This path is several REST calls and FM edits. **Sub-agents should NOT do
merges autonomously** — flag merge candidates back to the main session
for human-confirmed execution.

### 4. Report summary

```
Reviewed N pairs:
  rejected (false positive):     <count>
  added cross-references:        <count>
  flagged as contradictions:     <count>
  merged:                        <count>  ← destructive, list paths
<remaining> still pending. Run /vault-review-duplicates again for the next batch.
```

## Sub-agent mode (`--auto`)

**Model: Sonnet** (bumped from Haiku 2026-05-01 — see
[[topics/sub-agent-model-selection-by-task-shape]] evaluation log).

The 2026-05-01 second-batch eval (refreshed pool with diverse decisions
at distance 0.18-0.30) showed Haiku's pair-level decisions were
reasonable (~9 add-related, ~18 reject, no merges flagged) — but the
**FM-write implementation was destructive**: 15 files corrupted by
malformed PUT bodies that drowned the original body under a
duplicate-FM block. Files were git-restorable but the data-loss surface
made Haiku unsafe. Writer was hardened in c95a96c to reject the
malformed shape, but the cost-of-one-bad-output for this skill is now
documented as DESTRUCTIVE-FM-WRITE rather than just "closed-enum
triage" — same asymmetry as `/vault-review-tags` (wrong-reject strips
tags from records).

Sonnet's track record on `/vault-review-edges` and `/vault-review-tags`
confirms it follows multi-step file-edit recipes correctly. Use it
here too.

```
subagent_type: general-purpose
model: sonnet
description: Triage N pending duplicate suggestions
prompt: |
  Read ~/.claude/skills/vault-review-duplicates/SKILL.md and follow the
  procedure for the next $LIMIT pending duplicate suggestions.

  IMPORTANT BIAS: never auto-merge. If a pair looks like a true duplicate,
  flag it as MERGE_CANDIDATE in your return summary for the main session
  to handle — do NOT call DELETE on any file. Your safe paths are:
    - reject (false positive)
    - add related-to (two FM writes + accept)
    - flag as contradiction (return as flagged for human review)

  Decision bias: when in doubt between "add related-to" and "reject",
  prefer reject. Cross-references should reflect real semantic kinship,
  not just embedding-model coincidence.

  Return: {rejected: [...], related_added: [...], merge_candidates: [...],
  contradictions: [...], summary: "<one paragraph>"}
```

The main session reviews `merge_candidates` and decides which (if any) to
execute as actual merges with user confirmation.

## When this is the right tool

- The duplicate-detection scan has populated the queue.
- The user wants to clean up redundant notes.
- A `/vault resume` shows pending `duplicate` suggestions.

## When NOT to use

- The user wants to find duplicates *now* (without prior filing) — run
  `vault-curl /maintenance/find-duplicates -X POST` first, then this skill.
- The user wants to triage `edge_type` (use `/vault-review-edges`) or
  `new_tag` (use `/vault-review-tags`) — different suggestion kinds.

## Backend requirement

vault-storage on `:8123`. The maintenance scan and the duplicate-suggestion
schema are server-side. Obsidian's REST API has no equivalent.

## Dependencies

- `vault-curl` on `$PATH`.
- `jq` for response parsing.
