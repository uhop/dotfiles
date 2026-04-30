#!/usr/bin/env node
// Tool-call profiler: walks Claude Code session transcripts under
// ~/.claude/projects/**/*.jsonl, pairs tool_use with tool_result by id,
// and reports aggregate counts/latencies per tool name.
//
// Usage:
//   profile.mjs                    # all projects, all time
//   profile.mjs --days 7           # only sessions modified in last 7 days
//   profile.mjs --project NAME     # only the project dir matching NAME (basename)
//   profile.mjs --include-sidechain  # include sub-agent (Task) transcripts
//   profile.mjs --top N            # cap report rows (default 20)
//   profile.mjs --json             # emit JSON instead of markdown

import {readdirSync, readFileSync, statSync} from 'node:fs';
import {join} from 'node:path';
import {homedir} from 'node:os';

const args = process.argv.slice(2);
const flag = name => args.indexOf(name) !== -1;
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i === -1 ? fallback : args[i + 1];
};

const DAYS = opt('--days') ? Number(opt('--days')) : null;
const PROJECT_FILTER = opt('--project') ?? null;
const INCLUDE_SIDECHAIN = flag('--include-sidechain');
const TOP = opt('--top') ? Number(opt('--top')) : 20;
const AS_JSON = flag('--json');

const ROOT = join(homedir(), '.claude', 'projects');
const cutoffMs = DAYS != null ? Date.now() - DAYS * 86400 * 1000 : 0;

const transcriptFiles = [];
for (const projectDir of readdirSync(ROOT)) {
  if (PROJECT_FILTER && !projectDir.includes(PROJECT_FILTER)) continue;
  const projectPath = join(ROOT, projectDir);
  let entries;
  try {
    entries = readdirSync(projectPath);
  } catch {
    continue;
  }
  for (const entry of entries) {
    if (!entry.endsWith('.jsonl')) continue;
    const fp = join(projectPath, entry);
    const stat = statSync(fp);
    if (cutoffMs && stat.mtimeMs < cutoffMs) continue;
    transcriptFiles.push({path: fp, project: projectDir, mtime: stat.mtimeMs});
  }
}

// Pair tool_use → tool_result by id. tool_use timestamps come from the
// assistant message line; tool_result timestamps from the user message line.
const stats = new Map(); // tool_name → {count, latencies[], unmatched}
const ensure = name => {
  let s = stats.get(name);
  if (!s) {
    s = {count: 0, latencies: [], unmatched: 0};
    stats.set(name, s);
  }
  return s;
};

let sessionsAnalyzed = 0;
let totalUseEvents = 0;
let totalResultEvents = 0;

for (const {path: fp} of transcriptFiles) {
  const content = readFileSync(fp, 'utf8');
  // toolUseId → {name, t_start}
  const pending = new Map();
  let sessionTouched = false;

  for (const line of content.split('\n')) {
    if (line.length === 0) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }

    if (!INCLUDE_SIDECHAIN && row.isSidechain === true) continue;

    const ts = row.timestamp ? Date.parse(row.timestamp) : null;
    if (cutoffMs && ts && ts < cutoffMs) continue;

    if (row.type === 'assistant' && row.message?.content) {
      for (const block of row.message.content) {
        if (block.type === 'tool_use' && block.id && block.name) {
          pending.set(block.id, {name: block.name, t_start: ts});
          totalUseEvents++;
          sessionTouched = true;
        }
      }
    } else if (row.type === 'user' && row.message?.content) {
      const content = row.message.content;
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        if (block.type === 'tool_result' && block.tool_use_id) {
          totalResultEvents++;
          const entry = pending.get(block.tool_use_id);
          if (entry) {
            const s = ensure(entry.name);
            s.count++;
            if (entry.t_start != null && ts != null) {
              s.latencies.push(ts - entry.t_start);
            }
            pending.delete(block.tool_use_id);
          }
        }
      }
    }
  }

  // Anything still pending = call in flight at session end (interrupted /
  // crashed / still running). Count as unmatched per tool.
  for (const {name} of pending.values()) {
    ensure(name).unmatched++;
  }
  if (sessionTouched) sessionsAnalyzed++;
}

const pct = (sorted, p) => {
  if (sorted.length === 0) return null;
  const idx = Math.min(sorted.length - 1, Math.floor((sorted.length * p) / 100));
  return sorted[idx];
};

const fmt = ms => {
  if (ms == null) return '—';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${(ms / 60_000).toFixed(1)}m`;
};

const rows = [];
for (const [name, s] of stats) {
  const sorted = [...s.latencies].sort((a, b) => a - b);
  const total = s.latencies.reduce((sum, x) => sum + x, 0);
  rows.push({
    name,
    count: s.count,
    unmatched: s.unmatched,
    total_ms: total,
    p50_ms: pct(sorted, 50),
    p95_ms: pct(sorted, 95),
    avg_ms: s.latencies.length === 0 ? null : Math.round(total / s.latencies.length)
  });
}

const grandTotal = rows.reduce((sum, r) => sum + r.total_ms, 0);
const grandCount = rows.reduce((sum, r) => sum + r.count, 0);

if (AS_JSON) {
  console.log(
    JSON.stringify(
      {
        sessions_analyzed: sessionsAnalyzed,
        total_use_events: totalUseEvents,
        total_result_events: totalResultEvents,
        total_calls: grandCount,
        total_wall_time_ms: grandTotal,
        rows
      },
      null,
      2
    )
  );
} else {
  const sortedByTotal = [...rows].sort((a, b) => b.total_ms - a.total_ms);
  const sortedByCount = [...rows].sort((a, b) => b.count - a.count);

  const filterDesc =
    (DAYS != null ? `last ${DAYS} days` : 'all time') +
    (PROJECT_FILTER ? `, project=${PROJECT_FILTER}` : '') +
    (INCLUDE_SIDECHAIN ? ', incl. sidechains' : ', main only');

  console.log(`# Tool-call profile (${filterDesc})`);
  console.log();
  console.log(`Sessions analyzed: **${sessionsAnalyzed}**`);
  console.log(`Total tool calls: **${grandCount}** (across ${rows.length} distinct tools)`);
  console.log(`Wall-clock total: **${fmt(grandTotal)}**`);
  console.log();

  const renderTable = list => {
    console.log('| Tool | Calls | Total | p50 | p95 | Avg |');
    console.log('| ---- | ----- | ----- | --- | --- | --- |');
    for (const r of list.slice(0, TOP)) {
      console.log(
        `| ${r.name} | ${r.count}${r.unmatched > 0 ? ` (+${r.unmatched} pending)` : ''} | ${fmt(r.total_ms)} | ${fmt(r.p50_ms)} | ${fmt(r.p95_ms)} | ${fmt(r.avg_ms)} |`
      );
    }
  };

  console.log(`## By total wall time (top ${TOP})`);
  console.log();
  renderTable(sortedByTotal);
  console.log();
  console.log(`## By call count (top ${TOP})`);
  console.log();
  renderTable(sortedByCount);
}
