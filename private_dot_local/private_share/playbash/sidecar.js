// share/playbash/sidecar.js — sidecar JSON-lines parsing, per-host summary
// rendering, and cross-host event aggregation.
//
// Imports COLOR from ./render.js so the rendered summary uses the same
// palette as the live status board.

import {COLOR} from './render.js';

export function parseSidecar(text) {
  const events = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      process.stderr.write(`playbash: ignoring malformed sidecar line: ${line}\n`);
    }
  }
  return events;
}

// Per-host summary printer. Group order: actions first (most actionable),
// then warnings (FYI), then errors (recorded but non-fatal), then info
// (verbose only). The host status glyph already captured fatal pass/fail.
//
// Dedupe at the renderer: when several scripts on the same host emit the
// same (level, kind, target, msg) event (e.g. upd reports
// `reboot "kernel updated"` and cln reports the same thing later), the
// user wants to see one line, not several. The full record is preserved
// in the sidecar / log file regardless.
export function renderSummary(events, {verbose}) {
  if (events.length === 0) return;
  const seen = new Set();
  const unique = [];
  for (const ev of events) {
    const key = `${ev.level}\x00${ev.kind || ''}\x00${ev.target || ''}\x00${ev.msg}`;
    if (seen.has(key)) continue;
    seen.add(key);
    unique.push(ev);
  }
  const byLevel = {action: [], warn: [], error: [], info: []};
  for (const ev of unique) if (byLevel[ev.level]) byLevel[ev.level].push(ev);

  for (const ev of byLevel.action) {
    const kind = ev.kind || 'unknown';
    const target = ev.target ? ` ${COLOR.dim}[${ev.target}]${COLOR.reset}` : '';
    process.stderr.write(`  ${COLOR.magenta}⏵${COLOR.reset} ${kind}${target} ${COLOR.dim}·${COLOR.reset} ${ev.msg}\n`);
  }
  for (const ev of byLevel.warn) {
    const target = ev.target ? `${ev.target} ${COLOR.dim}·${COLOR.reset} ` : '';
    process.stderr.write(`  ${COLOR.orange}⚠${COLOR.reset} ${target}${ev.msg}\n`);
  }
  for (const ev of byLevel.error) {
    process.stderr.write(`  ${COLOR.red}✖${COLOR.reset} ${ev.msg}\n`);
  }
  if (verbose) {
    for (const ev of byLevel.info) {
      const step = ev.step ? `${COLOR.dim}[${ev.step}]${COLOR.reset} ` : '';
      process.stderr.write(`  ${COLOR.dim}·${COLOR.reset} ${step}${ev.msg}\n`);
    }
  }
}

// Cross-host event aggregator. Groups warn/action events by (level,kind,target)
// across all hosts and produces a list of {level, kind, target, msg, hosts[]}.
// Includes only events that span 2+ hosts (single-host events are already
// shown in the per-host block).
//
// Per-slot dedupe: each host contributes at most one occurrence per
// group key, even if it emitted the same event many times (e.g. upd
// fires `reboot "kernel updated"` and cln fires it again later → one
// host count, not two). This is the cross-host counterpart to the
// per-host renderSummary dedupe.
export function aggregateEvents(slots) {
  const groups = new Map();
  for (const slot of slots) {
    const seenInSlot = new Set();
    for (const ev of slot.events || []) {
      if (ev.level !== 'warn' && ev.level !== 'action') continue;
      const key = `${ev.level}\x00${ev.kind || ''}\x00${ev.target || ''}`;
      if (seenInSlot.has(key)) continue;
      seenInSlot.add(key);
      let g = groups.get(key);
      if (!g) {
        g = {level: ev.level, kind: ev.kind, target: ev.target, msg: ev.msg, hosts: []};
        groups.set(key, g);
      }
      g.hosts.push(slot.name);
    }
  }
  return [...groups.values()].filter(g => g.hosts.length >= 2);
}

export function renderAggregated(aggregated) {
  if (aggregated.length === 0) return;
  process.stderr.write('\n');
  for (const g of aggregated) {
    const hostList = g.hosts.join(', ');
    const count = `${g.hosts.length} hosts`;
    if (g.level === 'action') {
      const kind = g.kind || 'unknown';
      const target = g.target ? ` ${COLOR.dim}[${g.target}]${COLOR.reset}` : '';
      process.stderr.write(`${COLOR.magenta}⏵${COLOR.reset} ${kind}${target} ${COLOR.dim}·${COLOR.reset} ${count}: ${COLOR.dim}${hostList}${COLOR.reset}\n`);
    } else {
      const target = g.target ? `${g.target} ${COLOR.dim}·${COLOR.reset} ` : '';
      process.stderr.write(`${COLOR.orange}⚠${COLOR.reset} ${target}${count}: ${COLOR.dim}${hostList}${COLOR.reset}\n`);
    }
  }
}
