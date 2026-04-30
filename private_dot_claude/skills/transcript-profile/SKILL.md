---
name: transcript-profile
description: Profile agent tool-call patterns by parsing Claude Code session transcripts under `~/.claude/projects/`. Reports per-tool call counts, total wall-time, and p50/p95/avg latencies. Use when the user asks "what are we doing most often", "what's the slowest tool", "where should we optimize", or invokes /transcript-profile. Source data is the JSONL session logs Claude Code writes locally; no external service.
user_invocable: true
---

# Transcript profile — what the agent spends time on

Walks every `~/.claude/projects/*/*.jsonl` session transcript, pairs each `tool_use` with its `tool_result` by id, and reports aggregate counts and latencies per tool. Answers the user's "where should we optimize?" question with measured data instead of guessing.

## Invocation

```
/transcript-profile                   # all projects, all time, top 20
/transcript-profile --days N          # only sessions modified in last N days
/transcript-profile --project NAME    # filter to a project dir whose name contains NAME
/transcript-profile --top N           # cap report rows (default 20)
/transcript-profile --include-sidechain  # include sub-agent (Task) transcripts
/transcript-profile --json            # JSON output instead of markdown
```

Combinable. `--days 7 --project vault-storage --top 10` is a common shape for "what did vault-storage work look like this week."

## Procedure

1. **Run the script** verbatim with the user's args:

   ```bash
   node ~/.claude/skills/transcript-profile/profile.mjs $ARGUMENTS
   ```

   Output is markdown by default. The script handles arg parsing internally; pass `$ARGUMENTS` through.

2. **Highlight what stands out** in 2–4 bullets after the table:

   - Which tool dominates total time? (Usually Bash, by a wide margin — long-running tests/builds/installs.)
   - Which tool has the worst p95 vs p50 ratio? (Outliers — often web fetches or long Bash commands.)
   - Are MCP tools (`mcp__*`) showing high per-call latency? Network/round-trip overhead is worth flagging.
   - Are there tools the user might not realize are being called heavily?

3. **Don't read into the "pending" count** unless it's a large fraction. A small pending tail is normal — the most recent in-flight session shows up as unmatched, and very long-context sessions can lose tool_use/result pairs across a compaction boundary. The counts stay correct; the latency stats are computed from matched pairs only, so they're not skewed by pending.

## Data shape (for reference)

Each transcript line is one of: a session-meta record (permission mode, snapshot), a user message (with `tool_result` blocks in `message.content`), or an assistant message (with `tool_use` blocks). Top-level `timestamp` is when the line was written; pairing `assistant.tool_use.id` with `user.message.content[].tool_use_id` recovers latency.

`isSidechain: true` marks calls inside a sub-agent (a Task). Excluded by default — they double-count work that the parent's `Task` call already includes in its own latency. Add `--include-sidechain` to drill into sub-agent breakdowns.

## When the report is useful

- After a long stretch of work, asking "what should we optimize?" — the dominant total-time tool is the answer 90% of the time.
- Comparing pre/post a change to see if it actually saved wall time.
- Spotting drift in tool latency — if a previously-fast tool starts averaging 5× higher, something regressed.
- Validating that a new tool (e.g., a fresh MCP integration) has acceptable per-call overhead.

## When it's NOT the right tool

- Per-call args / specific commands run — the script aggregates by tool name only, not args. (Future: add `--by-args` for Bash subcommand bucketing.)
- Server-side latency in tools that hit external services. The "tool wall time" includes network + remote work; you can't separate them from this data alone.
