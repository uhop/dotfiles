// share/playbash/commands.js — small standalone subcommand implementations.
//
// Each function here implements one of the simple `playbash <verb>`
// subcommands that doesn't need the runner machinery: `list`, `hosts`,
// `log`, the hidden `__complete-targets`, and `--bash-completion`.
//
// All of these are small, synchronous-or-trivially-async, and have no
// shared state with each other. They live in their own module so the
// entry point file can stay focused on argv → dispatch.

import {readFileSync, readdirSync, statSync, unlinkSync, rmdirSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

import {COLOR, sanitizeForRect, stripAnsi} from './render.js';
import {die} from './errors.js';
import {isSelfAddress, loadInventory} from './inventory.js';
import {parseHostNames} from './ssh-config.js';
import {LOG_DIR, PLAYBOOK_DIR, PLAYBOOK_PREFIX} from './paths.js';

// --- log ---

// Walk a directory tree and find the file with the lexicographically
// largest name ending in `.log`. Per-run logs are named `<ISO-8601>.log`,
// so lexicographic order = chronological order — the largest name is
// the most recent run.
function latestLogUnder(dir) {
  let best = null;
  let bestName = '';
  let entries;
  try {
    entries = readdirSync(dir, {withFileTypes: true});
  } catch {
    return null;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      const deeper = latestLogUnder(join(dir, e.name));
      if (deeper && deeper.name > bestName) {
        best = deeper.path;
        bestName = deeper.name;
      }
    } else if (e.name.endsWith('.log') && e.name > bestName) {
      bestName = e.name;
      best = join(dir, e.name);
    }
  }
  return best ? {path: best, name: bestName} : null;
}

export function cmdLog(hostArg, commandArg) {
  let target;

  if (hostArg && (hostArg.includes('/') || hostArg.endsWith('.log'))) {
    target = hostArg;
  } else if (hostArg && commandArg) {
    const found = latestLogUnder(join(LOG_DIR, hostArg, commandArg));
    if (!found) die(`no logs for ${hostArg}/${commandArg}`);
    target = found.path;
  } else if (hostArg) {
    const found = latestLogUnder(join(LOG_DIR, hostArg));
    if (!found) die(`no logs for host ${hostArg}`);
    target = found.path;
  } else {
    const found = latestLogUnder(LOG_DIR);
    if (!found) die(`no logs in ${LOG_DIR}`);
    target = found.path;
  }

  let raw;
  try {
    raw = readFileSync(target);
  } catch (err) {
    die(`cannot read ${target}: ${err.message}`);
  }
  process.stdout.write(sanitizeForRect(raw));
  process.stderr.write(`\nplaybash: log ${target}\n`);
}

// --- log --stats ---

// Walk a directory, collecting {files, bytes} per relative two-level key
// (host/command for nested layout). Flat legacy logs at root go under
// the "(flat)" host bucket with command extracted where possible.
function collectLogEntries(root) {
  const entries = []; // [{host, command, path, size, mtime}]
  let dirItems;
  try { dirItems = readdirSync(root, {withFileTypes: true}); } catch { return entries; }
  for (const e of dirItems) {
    const p = join(root, e.name);
    if (e.isDirectory()) {
      // Nested layout: host → command → *.log
      let commands;
      try { commands = readdirSync(p, {withFileTypes: true}); } catch { continue; }
      for (const cmd of commands) {
        if (!cmd.isDirectory()) continue;
        const cmdDir = join(p, cmd.name);
        let logs;
        try { logs = readdirSync(cmdDir); } catch { continue; }
        for (const f of logs) {
          if (!f.endsWith('.log')) continue;
          try {
            const st = statSync(join(cmdDir, f));
            entries.push({host: e.name, command: cmd.name, path: join(cmdDir, f), size: st.size, mtime: st.mtimeMs});
          } catch {}
        }
      }
    } else if (e.name.endsWith('.log')) {
      // Flat legacy: <timestamp>Z-<host>-<command>.log
      try {
        const st = statSync(p);
        entries.push({host: '(flat)', command: '', path: p, size: st.size, mtime: st.mtimeMs});
      } catch {}
    }
  }
  return entries;
}

function humanSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
}

// Group entries by a key function, returning Map<string, {files, bytes}>.
function groupBy(entries, keyFn) {
  const map = new Map();
  for (const e of entries) {
    const k = keyFn(e);
    const bucket = map.get(k) || {files: 0, bytes: 0};
    bucket.files++;
    bucket.bytes += e.size;
    map.set(k, bucket);
  }
  return map;
}

function printTable(rows, indent = '') {
  if (rows.length === 0) return;
  const widths = rows[0].map((_, col) =>
    Math.max(...rows.map(r => stripAnsi(r[col]).length))
  );
  for (const row of rows) {
    const line = row.map((cell, i) => {
      const pad = widths[i] - stripAnsi(cell).length;
      return i === 0 ? cell + ' '.repeat(pad) : ' '.repeat(pad) + cell;
    }).join('  ');
    process.stdout.write(`${indent}${line}\n`);
  }
}

export function cmdLogStats(hostArg, commandArg, byCommand) {
  const all = collectLogEntries(LOG_DIR);

  // Filter to scope
  const entries = hostArg
    ? all.filter(e => e.host === hostArg && (!commandArg || e.command === commandArg))
    : all;

  if (entries.length === 0) {
    const scope = commandArg ? `${hostArg}/${commandArg}` : hostArg || LOG_DIR;
    process.stdout.write(`no logs in ${scope}\n`);
    return;
  }

  if (hostArg || byCommand) {
    // Per-command breakdown (when scoped to a host, or --by-command globally)
    if (hostArg && !byCommand) {
      // Single host: show per-command
      const byCmd = groupBy(entries, e => e.command || '(flat)');
      const rows = [...byCmd.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([cmd, s]) => [cmd, `${s.files}`, humanSize(s.bytes)]);
      rows.unshift([`${COLOR.dim}command${COLOR.reset}`, `${COLOR.dim}files${COLOR.reset}`, `${COLOR.dim}size${COLOR.reset}`]);
      printTable(rows, '  ');
    } else {
      // Global --by-command: per-host, each with per-command sub-table
      const byHost = new Map();
      for (const e of entries) {
        if (!byHost.has(e.host)) byHost.set(e.host, []);
        byHost.get(e.host).push(e);
      }
      for (const host of [...byHost.keys()].sort()) {
        const hostEntries = byHost.get(host);
        const hostBytes = hostEntries.reduce((s, e) => s + e.size, 0);
        process.stdout.write(
          `  ${COLOR.bold}${host}${COLOR.reset}  ${hostEntries.length} file${hostEntries.length === 1 ? '' : 's'}, ${humanSize(hostBytes)}\n`
        );
        const byCmd = groupBy(hostEntries, e => e.command || '(flat)');
        const rows = [...byCmd.entries()]
          .sort(([a], [b]) => a.localeCompare(b))
          .map(([cmd, s]) => [cmd, `${s.files}`, humanSize(s.bytes)]);
        printTable(rows, '    ');
        process.stdout.write('\n');
      }
    }
  } else {
    // Per-host breakdown (default)
    const byHost = groupBy(entries, e => e.host);
    const rows = [...byHost.entries()]
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([host, s]) => [host, `${s.files}`, humanSize(s.bytes)]);
    rows.unshift([`${COLOR.dim}host${COLOR.reset}`, `${COLOR.dim}files${COLOR.reset}`, `${COLOR.dim}size${COLOR.reset}`]);
    printTable(rows, '  ');
  }

  const totalBytes = entries.reduce((s, e) => s + e.size, 0);
  process.stdout.write(
    `\n${COLOR.bold}${entries.length}${COLOR.reset} log file${entries.length === 1 ? '' : 's'}, ` +
    `${COLOR.bold}${humanSize(totalBytes)}${COLOR.reset} in ${LOG_DIR}\n`
  );
}

// --- log --prune ---

function parseAge(str) {
  const m = /^(\d+)([wdhm])$/.exec(str);
  if (!m) return null;
  const n = parseInt(m[1], 10);
  const unit = m[2];
  const ms = unit === 'w' ? n * 604800000 : unit === 'd' ? n * 86400000 : unit === 'h' ? n * 3600000 : n * 60000;
  return ms;
}

// Remove empty directories bottom-up under root (but not root itself).
function pruneEmptyDirs(dir) {
  let entries;
  try { entries = readdirSync(dir, {withFileTypes: true}); } catch { return; }
  for (const e of entries) {
    if (e.isDirectory()) pruneEmptyDirs(join(dir, e.name));
  }
  // Re-read after children may have been removed
  try { entries = readdirSync(dir); } catch { return; }
  if (entries.length === 0) {
    try { rmdirSync(dir); } catch {}
  }
}

export function cmdLogPrune(hostArg, commandArg, ageStr, apply, verbose) {
  const ms = parseAge(ageStr);
  if (ms == null) die(`invalid age "${ageStr}" — use e.g. 2w, 7d, 24h, 30m`);

  const cutoff = Date.now() - ms;
  const all = collectLogEntries(LOG_DIR);
  const entries = hostArg
    ? all.filter(e => e.host === hostArg && (!commandArg || e.command === commandArg))
    : all;

  const old = entries.filter(e => e.mtime < cutoff);
  if (old.length === 0) {
    const scope = commandArg ? `${hostArg}/${commandArg}` : hostArg || 'any host';
    process.stdout.write(`no logs older than ${ageStr} for ${scope}\n`);
    return;
  }

  const totalBytes = old.reduce((s, e) => s + e.size, 0);
  if (!apply) {
    if (verbose) {
      for (const e of old) {
        const rel = e.path.slice(LOG_DIR.length + 1);
        process.stdout.write(`  ${COLOR.dim}${rel}${COLOR.reset}\n`);
      }
      process.stdout.write('\n');
    }
    process.stdout.write(
      `${COLOR.bold}dry run${COLOR.reset} — would delete ${old.length} file${old.length === 1 ? '' : 's'}, ${humanSize(totalBytes)}\n`
    );
    process.stdout.write(`re-run with --apply to delete\n`);
    return;
  }

  let deleted = 0, freedBytes = 0, errors = 0;
  for (const e of old) {
    try {
      unlinkSync(e.path);
      deleted++;
      freedBytes += e.size;
    } catch {
      errors++;
    }
  }
  pruneEmptyDirs(LOG_DIR);
  process.stdout.write(
    `deleted ${deleted} file${deleted === 1 ? '' : 's'}, freed ${humanSize(freedBytes)}`
  );
  if (errors > 0) process.stdout.write(` (${errors} error${errors === 1 ? '' : 's'})`);
  process.stdout.write('\n');
}

// --- list ---

export function cmdList() {
  let entries;
  try {
    entries = readdirSync(PLAYBOOK_DIR);
  } catch (err) {
    die(`cannot read ${PLAYBOOK_DIR}: ${err.message}`);
  }
  // Playbooks are `playbash-<name>` (no extension). Defensive: ignore
  // any `.js` file that happens to share the prefix.
  const playbooks = entries
    .filter(f => f.startsWith(PLAYBOOK_PREFIX) && !f.endsWith('.js'))
    .map(f => f.slice(PLAYBOOK_PREFIX.length))
    .sort();
  if (playbooks.length === 0) {
    process.stderr.write(
      `no playbooks found in ${PLAYBOOK_DIR} (looking for ${PLAYBOOK_PREFIX}*) — run 'playbash doctor' to diagnose\n`
    );
    return;
  }
  for (const p of playbooks) process.stdout.write(`${p}\n`);
}

// --- hosts ---

export async function cmdHosts() {
  const inv = loadInventory();
  const hostNames = inv.present ? [...inv.hosts.keys()].sort() : [];
  const groupNames = inv.present ? [...inv.groups.keys()].sort() : [];

  // Inventory-level notices go to stderr so they don't pollute the host
  // list on stdout, but we continue to the ssh-only section regardless —
  // a user without an inventory may still have working ssh aliases and
  // deserves to see them here.
  if (!inv.present) {
    process.stderr.write(`no inventory at ${inv.path}\n`);
  } else if (hostNames.length === 0 && groupNames.length === 0) {
    process.stderr.write(`inventory at ${inv.path} is empty\n`);
  }

  if (hostNames.length > 0) {
    // Resolve each host to find which entries are self.
    const selfFlags = await Promise.all(
      hostNames.map(name => isSelfAddress(inv.hosts.get(name).address))
    );
    const width = Math.max(...hostNames.map(n => n.length));
    const addrWidth = Math.max(
      ...hostNames.map(n => inv.hosts.get(n).address.length)
    );
    for (let i = 0; i < hostNames.length; i++) {
      const name = hostNames[i];
      const addr = inv.hosts.get(name).address;
      const tag = selfFlags[i] ? '  (self)' : '';
      process.stdout.write(
        `${name.padEnd(width)}  ${addr.padEnd(addrWidth)}${tag}\n`
      );
    }
  }
  if (groupNames.length > 0) {
    process.stdout.write('\ngroups:\n');
    const width = Math.max(...groupNames.map(n => n.length));
    for (const name of groupNames) {
      process.stdout.write(
        `  ${name.padEnd(width)}  ${inv.groups.get(name).join(', ')}\n`
      );
    }
  }
  // Third section: ssh-config Host aliases that aren't in inventory.
  // These work as bare aliases at runtime (the dispatcher passes
  // unknown names verbatim to ssh) but are not part of `all` and don't
  // belong to any group. Surfacing them here makes them discoverable
  // alongside the canonical fleet. Shown regardless of inventory state —
  // a missing or empty inventory doesn't imply a missing ssh config.
  const inventoryNames = new Set(hostNames);
  const sshOnly = [...parseHostNames()]
    .filter(n => !inventoryNames.has(n))
    .sort();
  if (sshOnly.length > 0) {
    const printedAbove = hostNames.length > 0 || groupNames.length > 0;
    const prefix = printedAbove ? '\n' : '';
    process.stdout.write(`${prefix}${COLOR.dim}ssh aliases (not in inventory):${COLOR.reset}\n`);
    for (const name of sshOnly) process.stdout.write(`  ${name}\n`);
  }
}

// --- bash completion ---

// Hidden helper called by the bash completion script. Prints inventory
// host names + group names + the implicit `all`, plus literal Host
// entries from ~/.ssh/config (deduped against inventory). One name per
// line. No self detection (which would mean DNS lookups on every tab
// press) and no formatting — just names. Single source of truth: bash
// never parses inventory.json directly, so live changes are picked up
// on every tab.
export function cmdCompleteTargets() {
  // Suggestions are sourced from two places:
  //   1. Inventory: hosts, groups, and the implicit `all` group. These
  //      are the canonical fleet members and the only things `all` and
  //      group expansion know about at runtime.
  //   2. ~/.ssh/config: literal Host entries (no wildcards). These work
  //      as bare ssh aliases at runtime — the dispatcher passes unknown
  //      names verbatim to ssh — but completion didn't know about them
  //      until now, so the user had to type them from memory.
  // We merge both sources, dedupe (a name in both ends up once), and
  // emit alphabetically. Plain strings, no descriptions — see
  // dev-docs/bash-rich-completion.md if we ever want richer suggestions.
  const names = new Set();
  names.add('@self');
  const inv = loadInventory();
  if (inv.present) {
    names.add('all');
    for (const n of inv.hosts.keys()) names.add(n);
    for (const n of inv.groups.keys()) names.add(n);
  }
  for (const n of parseHostNames()) names.add(n);
  for (const n of [...names].sort()) process.stdout.write(`${n}\n`);
}

// Print the bash completion script to stdout. Sourced from ~/.bashrc via
// `eval "$(playbash --bash-completion)"` — same idiom as `zoxide init bash`.
// The script itself lives in completion.bash alongside the other playbash
// modules — a plain bash file editable with full IDE support.
export function cmdBashCompletion() {
  const script = readFileSync(
    join(homedir(), '.local', 'share', 'playbash', 'completion.bash'),
    'utf8'
  );
  process.stdout.write(script);
}
