---
name: vault-compact
description: "Compact an atomized folder of vault pieces by summarizing the oldest entries into a single summary file and archiving the originals to `<folder>/archive/`. Use when the user says /vault-compact <folder>, asks to summarize a verbose project's logs/decisions, or wants to bound a running file's size per the vault's hygiene policy. Originals are preserved (move not delete). Manual-invocation today; future server-side maintenance scan will file `compaction_candidate` suggestions for the queue. Requires vault-storage (`:8123`)."
user_invocable: true
---

# Vault — compact a folder of pieces

Some folders accumulate pieces that no longer pull their weight individually
but still carry value as compressed history. `logs/` is the obvious case:
each session log was useful at the time of writing, but reading 12 months
of session logs at session-start is wasteful — a compacted summary
("here's what happened January through March") preserves the signal at
1/20th the token cost.

This skill reads N oldest pieces in a folder, writes a single summary
file, and moves the originals to `<folder>/archive/<YYYY>/`. Originals
are reachable via direct read; default `/vault resume` doesn't descend
into `archive/`. Per design constraint C7 (bounded running-file size).

**Manual-invocation today.** The server-side maintenance scan that files
`compaction_candidate` suggestions automatically when a folder crosses
size/piece-count thresholds is deferred — needs threshold calibration
against real vault growth. For now: invoke explicitly for folders the
user identifies.

## Invocation

```
/vault-compact <folder>                        # summarize oldest 50% of pieces
/vault-compact <folder> --keep=N               # keep newest N pieces; archive the rest
/vault-compact <folder> --before=YYYY-MM-DD    # archive everything older than a date
/vault-compact <folder> --dry-run              # report what would change without writing
```

The folder argument is vault-relative, e.g. `logs`, `projects/foo/decisions`.

## Procedure

### 1. Inventory the folder

```bash
vault-curl "/vault/$FOLDER/" -s | jq -r '.files[]'
```

For each file (skip subdirectories — those are deeper sub-folders, not
pieces). Read the frontmatter via `/sections?file_prefix=$FOLDER` to get
`created` / `updated` / `type` per piece without pulling bodies.

```bash
vault-curl "/sections?file_prefix=$FOLDER&limit=200&exclude=body&sort=created" -s
```

### 2. Decide what to archive

Three modes per the invocation flags:

- **Default** (no flag): archive the oldest 50% of pieces. Cap at archiving
  no more than N=20 in a single pass — better to call repeatedly for
  large folders than to write a single mega-summary.
- **`--keep=N`**: archive everything except the newest N pieces (by `created` date).
- **`--before=DATE`**: archive every piece with `created < DATE`.

Pieces with `status: archived` are already moved out — exclude from this list.
Pieces of type `state` are managed by `/vault check` — exclude.

### 3. Read the pieces to archive

```bash
for FILE in $TO_ARCHIVE; do
  vault-curl "/vault/$FILE" -s
done
```

Group by sub-period. For `logs/`, group by month. For `projects/foo/decisions/`,
group by quarter or year. Pick whatever granularity gives ~5-10 pieces per
summary section so the resulting summary has structure.

### 4. Write the summary file

Save to `<folder>/_summary-<period>.md`:

```yaml
---
title: <Folder> — summary <YYYY-MM-DD to YYYY-MM-DD>
tags: [summary, <folder-tag>, archived-history]
created: <today>
updated: <today>
status: active
type: meta
related: ["[[<one-or-two-current-source-notes>]]"]
---
```

Body: one section per sub-period. For each section, distill the pieces
into a cohesive paragraph or bulleted list. Surface:

- **What was done / decided / discovered** (the core signal of each piece)
- **Cross-references** that still matter (link to current notes, not archived ones)
- **Concrete identifiers**: dates, commit shas, names, numbers — these are
  the recall hooks
- **Surprises and unknowns** that didn't get resolved — sometimes the most
  valuable trace from a noisy log

What to **drop**: conversation-style paraphrasing ("the user asked X, I
replied Y"); progress narration ("first I tried this, then..."); general
context that's available elsewhere.

The goal: someone reading the summary 6 months from now should learn the
*outcome* of each archived piece without needing to open it. They can
still open it if they want — it's preserved, not deleted.

### 5. Move originals to archive

For each archived piece, write its content to `<folder>/archive/<YYYY>/<basename>`
and delete the original:

```bash
# Read original
CONTENT=$(vault-curl "/vault/$ORIGINAL_PATH" -s)
# Write to archive path
echo "$CONTENT" | vault-curl "/vault/$FOLDER/archive/$YEAR/$BASENAME" -X PUT \
  -H 'Content-Type: text/markdown' --data-binary @-
# Delete original
vault-curl "/vault/$ORIGINAL_PATH" -X DELETE -s
```

Wikilinks pointing at archived pieces will become unresolved on the next
reindex. That's by design (per [[topics/vault-hygiene-policy]]) — the
breakage is the signal that someone should either rewrite the link, archive
the linker, or accept the break.

### 6. Update inbound wikilinks (optional, per pass)

Run:

```bash
for ARCHIVED_ID in $ARCHIVED_RECORD_IDS; do
  vault-curl "/sections/$ARCHIVED_ID/backlinks" -s
done
```

For each backlink that's NOT itself being archived in this pass, decide:
update the link to point at the summary file, or leave it broken
(triggers a hygiene-lint flag for later cleanup). Default to leave-broken
unless the user has explicitly asked to rewrite.

### 7. Report

```
Compacted <folder>:
  archived: <count> pieces (<oldest-date> to <newest-archived-date>)
  summary written: <folder>/_summary-<period>.md
  pieces remaining in folder: <count>
  inbound wikilinks broken: <count>  (run /vault-lint for details, or rewrite manually)
```

## Sub-agent mode (deferred)

Compaction is heavier per-task than the review skills (writes summary
prose; needs to capture nuance). Sonnet may produce better summaries than
Haiku for high-stakes folders. The skill currently runs in the main
session.

When this skill matures (volume justifies sub-agent), the subagent prompt
should specify:
- **Summary quality bar**: paragraph-per-period; concrete identifiers
  preserved; outcomes named explicitly
- **Conservative cut**: when in doubt about archiving, keep — better to
  re-run later with looser thresholds than to over-compact early
- **Don't rewrite wikilinks** unless explicitly authorized

## When this is the right tool

- A folder has accumulated many pieces and is past the C7 size threshold.
- A `/vault resume` reads waste tokens on stale logs.
- The user wants to "summarize and archive" old session logs / project
  history.

## When NOT to use

- The folder is deliberately preserved as-is (e.g., `topics/` — every
  topic note stands on its own; compacting topics destroys the
  source-of-truth shape).
- The folder is small enough that compaction is premature.
- The user wants to *delete* old pieces (compaction is move-not-delete by
  design — different intent).

## Backend requirement

vault-storage on `:8123`. Path-based reads / writes / deletes are all REST
calls. Obsidian's REST API supports the same path operations but lacks the
record-level metadata queries (created dates, status, type) that the
piece-selection step uses.

## Dependencies

- `vault-curl` on `$PATH`.
- `jq` for response parsing.
