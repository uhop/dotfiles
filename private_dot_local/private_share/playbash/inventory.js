// share/playbash/inventory.js — inventory loading, target resolution, self detection.
//
// Pure(ish) module: no UI, no spawning. Throws via die() on user errors
// (invalid JSON, unknown groups, etc.) which exits with the same exit
// code the runner uses elsewhere — these are user-facing errors that
// belong on stderr regardless of which call site triggers them.

import {existsSync, readFileSync} from 'node:fs';
import {homedir, networkInterfaces} from 'node:os';
import {join} from 'node:path';
import {lookup as dnsLookup} from 'node:dns/promises';

import {die} from './errors.js';

export const INVENTORY_PATH = join(homedir(), '.config', 'playbash', 'inventory.json');

// --- Inventory ---

export function loadInventory() {
  const empty = {hosts: new Map(), groups: new Map(), path: INVENTORY_PATH, present: false};
  if (!existsSync(INVENTORY_PATH)) return empty;
  let raw;
  try {
    raw = JSON.parse(readFileSync(INVENTORY_PATH, 'utf8'));
  } catch (err) {
    die(`inventory at ${INVENTORY_PATH} is not valid JSON: ${err.message}`);
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    die(`inventory at ${INVENTORY_PATH} must be a JSON object`);
  }
  const hosts = new Map();
  const groups = new Map();
  for (const [name, value] of Object.entries(raw)) {
    if (typeof value === 'string') {
      hosts.set(name, {address: value});
    } else if (Array.isArray(value)) {
      // Group entry — loaded for `playbash hosts` and resolveTargets.
      groups.set(name, value);
    } else if (value && typeof value === 'object') {
      if (typeof value.address !== 'string') {
        die(`inventory entry "${name}" has no string "address"`);
      }
      hosts.set(name, value);
    } else {
      die(`inventory entry "${name}" has unsupported type`);
    }
  }
  return {hosts, groups, path: INVENTORY_PATH, present: true};
}

// Resolve a single name to an ssh-target string.
// If the name matches a host entry, return its address. Otherwise pass
// the name through verbatim so ~/.ssh/config aliases still work.
export function resolveHost(name, inventory) {
  const entry = inventory.hosts.get(name);
  return entry ? entry.address : name;
}

// Expand `arg` (a single CLI positional, possibly comma-separated, possibly
// containing host names, group names, or the implicit `all` group) into an
// ordered, deduped list of {name, address} entries.
//
// Resolution rules:
//   - Tokens are split on `,` and trimmed of whitespace.
//   - `all` expands to every host entry in inventory, alphabetically.
//   - A token matching a group name expands to its members in the order
//     they appear in the group definition.
//   - A token matching a host entry expands to that one host.
//   - An unknown token is treated as a literal — passed through to ssh,
//     same as a single-host call (so ~/.ssh/config aliases keep working).
//   - The result is deduped by name, preserving first-seen order.
//
// Groups are flat: a group's members must be host names, not other group
// names. An array entry whose member matches a group name is rejected
// with a clear error.
export function resolveTargets(arg, inventory) {
  const tokens = arg.split(',').map(t => t.trim()).filter(Boolean);
  if (tokens.length === 0) die('empty target list (pass a host name, group name, or "all")');
  const out = [];
  const seen = new Set();
  const push = (name, address) => {
    if (seen.has(name)) return;
    seen.add(name);
    out.push({name, address});
  };
  for (const tok of tokens) {
    if (tok === 'all') {
      const names = [...inventory.hosts.keys()].sort();
      for (const n of names) push(n, inventory.hosts.get(n).address);
      continue;
    }
    if (inventory.groups.has(tok)) {
      const members = inventory.groups.get(tok);
      for (const m of members) {
        if (inventory.groups.has(m)) {
          die(`group "${tok}" references group "${m}"; nested groups are not supported`);
        }
        const entry = inventory.hosts.get(m);
        if (!entry) {
          die(`group "${tok}" references unknown host "${m}"`);
        }
        push(m, entry.address);
      }
      continue;
    }
    // Plain host name (in inventory) or literal pass-through (for ssh-config aliases).
    push(tok, resolveHost(tok, inventory));
  }
  return out;
}

// Filter self entries out of a target list. Returns {targets, skipped}
// where `skipped` is the list of names that were dropped because they
// resolve to a local interface. When `keepSelf` is true, returns the
// original list unchanged (and skipped is empty).
export async function filterSelf(targets, keepSelf) {
  if (keepSelf) return {targets, skipped: []};
  const flags = await Promise.all(targets.map(t => isSelfAddress(t.address)));
  const kept = [];
  const skipped = [];
  for (let i = 0; i < targets.length; i++) {
    if (flags[i]) skipped.push(targets[i].name);
    else kept.push(targets[i]);
  }
  return {targets: kept, skipped};
}

// --- Self detection ---

// Set of IPs bound to any local interface, plus the loopback ranges.
// Computed once on demand.
let _localIps = null;
function localIpSet() {
  if (_localIps) return _localIps;
  const set = new Set();
  const ifaces = networkInterfaces();
  for (const list of Object.values(ifaces)) {
    if (!list) continue;
    for (const i of list) set.add(i.address);
  }
  // Loopback families. We don't enumerate 127.0.0.0/8 — just check the
  // prefix at lookup time. ::1 is added explicitly.
  set.add('::1');
  _localIps = set;
  return set;
}

function isLoopback(ip) {
  if (!ip) return false;
  if (ip === '::1') return true;
  return ip.startsWith('127.');
}

// Resolve `address` (a hostname or IP literal) and return true if it
// points at a local interface. DNS failure → false (conservative).
export async function isSelfAddress(address) {
  let ip;
  try {
    const res = await dnsLookup(address);
    ip = res.address;
  } catch {
    return false;
  }
  if (isLoopback(ip)) return true;
  return localIpSet().has(ip);
}
