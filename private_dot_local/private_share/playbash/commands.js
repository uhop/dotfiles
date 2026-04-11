// share/playbash/commands.js — small standalone subcommand implementations.
//
// Each function here implements one of the simple `playbash <verb>`
// subcommands that doesn't need the runner machinery: `list`, `hosts`,
// `log`, the hidden `__complete-targets`, and `--bash-completion`.
//
// All of these are small, synchronous-or-trivially-async, and have no
// shared state with each other. They live in their own module so the
// entry point file can stay focused on argv → dispatch.

import {readFileSync, readdirSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

import {COLOR, sanitizeForRect} from './render.js';
import {isSelfAddress, loadInventory} from './inventory.js';
import {parseHostNames} from './ssh-config.js';
import {LOG_DIR, PLAYBOOK_DIR, PLAYBOOK_PREFIX} from './paths.js';

function die(msg, code = 2) {
  process.stderr.write(`playbash: ${msg}\n`);
  process.exit(code);
}

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
      `no playbooks found in ${PLAYBOOK_DIR} (looking for ${PLAYBOOK_PREFIX}*)\n`
    );
    return;
  }
  for (const p of playbooks) process.stdout.write(`${p}\n`);
}

// --- hosts ---

export async function cmdHosts() {
  const inv = loadInventory();
  if (!inv.present) {
    process.stderr.write(`no inventory at ${inv.path}\n`);
    return;
  }
  const hostNames = [...inv.hosts.keys()].sort();
  const groupNames = [...inv.groups.keys()].sort();
  if (hostNames.length === 0 && groupNames.length === 0) {
    process.stderr.write(`inventory at ${inv.path} is empty\n`);
    return;
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
  // alongside the canonical fleet.
  const inventoryNames = new Set(hostNames);
  const sshOnly = [...parseHostNames()]
    .filter(n => !inventoryNames.has(n))
    .sort();
  if (sshOnly.length > 0) {
    process.stdout.write(`\n${COLOR.dim}ssh aliases (not in inventory):${COLOR.reset}\n`);
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
