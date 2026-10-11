// share/playbash/inventory.js — inventory loading, target resolution, self detection.
//
// Pure(ish) module: no UI, no spawning. Throws via die() on user errors
// (invalid JSON, unknown groups, etc.) which exits with the same exit
// code the runner uses elsewhere — these are user-facing errors that
// belong on stderr regardless of which call site triggers them.

import {existsSync, readFileSync} from 'node:fs';
import {homedir, hostname, networkInterfaces} from 'node:os';
import {join} from 'node:path';
import {lookup as dnsLookup} from 'node:dns/promises';

import {die} from './errors.js';

export const INVENTORY_PATH = join(homedir(), '.config', 'playbash', 'inventory.json');

// --- Inventory ---

// A string (or {"address": ...}) gives a host's ssh address; an array is a group. A group
// member names a group or a host, and `-name` removes one. A member that names no group
// is a host whose address defaults to its name, so a host needs its own entry only when
// the two differ. No group means anything to playbash (`all` included): each host says
// whether it has the playbooks installed. Every group is expanded here, so a broken one
// fails every command.
export function loadInventory() {
  const empty = {
    hosts: new Map(),
    groups: new Map(),
    expanded: new Map(),
    path: INVENTORY_PATH,
    present: false
  };
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
    checkName(name, `inventory entry "${name}"`);
    if (typeof value === 'string') {
      hosts.set(name, {address: value});
    } else if (Array.isArray(value)) {
      groups.set(name, value);
    } else if (value && typeof value === 'object') {
      if ('managed' in value) {
        die(
          `inventory entry "${name}" has "managed", which playbash no longer reads: ` +
            'a name the inventory does not list is refused, so delete the entry'
        );
      }
      if (typeof value.address !== 'string') {
        die(`inventory entry "${name}" has no string "address"`);
      }
      hosts.set(name, {address: value.address});
    } else {
      die(`inventory entry "${name}" has unsupported type`);
    }
  }
  for (const [group, members] of groups) {
    for (const member of members) {
      if (typeof member !== 'string')
        die(`group "${group}" has a member that is not a string`);
      const name = member.startsWith('-') ? member.slice(1) : member;
      checkName(name, `group "${group}" member "${member}"`);
      if (name === member && !groups.has(name) && !hosts.has(name)) {
        hosts.set(name, {address: name});
      }
    }
  }
  const expanded = new Map();
  const visiting = [];
  const expand = group => {
    if (expanded.has(group)) return expanded.get(group);
    const at = visiting.indexOf(group);
    if (at >= 0)
      die(
        `inventory groups form a cycle: ${[...visiting.slice(at), group].join(' → ')}`
      );
    visiting.push(group);
    const names = combine(groups.get(group), name => {
      if (groups.has(name)) return expand(name);
      if (hosts.has(name)) return [name];
      die(
        `group "${group}" removes "${name}", which is neither a host nor a group`
      );
    });
    visiting.pop();
    expanded.set(group, names);
    return names;
  };
  for (const group of groups.keys()) expand(group);

  return {
    hosts,
    groups,
    expanded,
    path: INVENTORY_PATH,
    present: true
  };
}

// Commas split a target list, a leading `-` removes, and `@self` is a command-line word.
function checkName(name, where) {
  if (
    !name ||
    name.includes(',') ||
    name.startsWith('-') ||
    name.startsWith('@')
  ) {
    die(
      `${where}: a name must be non-empty, hold no comma, and start with neither "-" nor "@"` +
        ' (@self works on the command line only)'
    );
  }
}

// Every removal applies after every addition, so a member's position never matters.
function combine(members, expandName) {
  const added = [];
  const removed = new Set();
  for (const member of members) {
    if (member.startsWith('-')) {
      for (const name of expandName(member.slice(1))) removed.add(name);
    } else {
      added.push(...expandName(member));
    }
  }
  return [...new Set(added)].filter(name => !removed.has(name));
}

// Expand `arg` (one CLI positional: comma-separated tokens) into an ordered, deduped list
// of {name, address, isSelf?}. A token is a group, a host, or `@self`, and `-token`
// removes one, by the same rules as group members. A name the inventory does not list is
// refused. `@self` is this machine under its hostname; its address is `localhost` even
// when the inventory lists that name, so it runs locally whatever DNS says.
export function resolveTargets(arg, inventory) {
  const tokens = arg
    .split(',')
    .map(t => t.trim())
    .filter(Boolean);
  if (tokens.length === 0) die('empty target list (pass a host or group name)');
  if (tokens.includes('-'))
    die('a "-" in a target list must be followed by a host or group name');
  const selfName = hostname();
  const selfNamed = tokens.includes('@self');
  const names = combine(tokens, name => {
    if (name === '@self') return [selfName];
    if (inventory.expanded.has(name)) return inventory.expanded.get(name);
    if (inventory.hosts.has(name)) return [name];
    die(
      inventory.present
        ? `"${name}" is not in the inventory at ${inventory.path}; playbash reaches only the hosts and groups listed there`
        : `"${name}" is not in an inventory: there is none at ${inventory.path}`
    );
  });
  return names.map(name =>
    selfNamed && name === selfName
      ? {name, address: 'localhost', isSelf: true}
      : {name, address: inventory.hosts.get(name).address}
  );
}

// Split a target list into the targets to run and the names skipped as this machine: a
// target that resolves to a local interface runs only as the `@self` entry.
export async function filterSelf(targets) {
  const flags = await Promise.all(
    targets.map(t => !t.isSelf && isSelfAddress(t.address))
  );
  const kept = [];
  const skipped = [];
  for (let i = 0; i < targets.length; ++i) {
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
