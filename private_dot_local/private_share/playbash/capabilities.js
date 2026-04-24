// share/playbash/capabilities.js — remote host capability detection + cache.
//
// Right now there's exactly one capability tracked: whether zstd is present
// on the *remote* host, which decides whether `playbash put`/`get` on
// directories and `stagePlaybookDir` compress the tar stream before ssh.
// The module is written so future capability probes (xz, a specific tar
// feature) can be added without reshaping the cache file.
//
// Local-side compression uses Node's built-in `zlib.createZstdCompress` /
// `createZstdDecompress` (available since Node 22.15, April 2025). That's
// why the cache is remote-only — `localHasZstd()` is a static feature
// check, not an ssh probe. Older Nodes return false from `localHasZstd`
// and the pipeline falls through to raw tar.
//
// Cache layout: one JSON file per host under ~/.cache/playbash/capabilities/
// <hostName>.json. Shape:
//
//   { "zstd": true, "probedAt": "2026-04-24T17:14:02Z" }
//
// Invalidation policy: never-expire. zstd presence on a host is stable
// across days/weeks. If the operator installs zstd on a host that previously
// lacked it, `playbash doctor` re-probes and overwrites the cache.
// Alternatively: `rm ~/.cache/playbash/capabilities/<host>.json`.

import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {createZstdCompress} from 'node:zlib';

import {sshRun} from './staging.js';

const CACHE_DIR = join(homedir(), '.cache', 'playbash', 'capabilities');

// --- local feature check ---

// Static per Node version — `createZstdCompress` is present on Node 22.15+
// and every release since. No ssh, no spawn, no cache.
export function localHasZstd() {
  return typeof createZstdCompress === 'function';
}

// --- remote probe + cache ---

function cachePath(hostName) {
  return join(CACHE_DIR, `${hostName}.json`);
}

function loadCache(hostName) {
  try {
    return JSON.parse(readFileSync(cachePath(hostName), 'utf8'));
  } catch {
    return null;
  }
}

function saveCache(hostName, entry) {
  mkdirSync(CACHE_DIR, {recursive: true});
  writeFileSync(cachePath(hostName), JSON.stringify(entry) + '\n');
}

// One ssh round trip: `command -v zstd >/dev/null 2>&1 && echo yes || echo no`.
// The if/then/else shape avoids the `a && b || c` pitfall (if `echo yes`
// itself somehow failed, `|| echo no` would fire). Errors or unparseable
// output are treated as "no" so the pipeline falls through to raw tar.
export async function probeRemoteZstd(address) {
  try {
    const r = await sshRun(
      address,
      'if command -v zstd >/dev/null 2>&1; then echo yes; else echo no; fi',
    );
    if (r.code !== 0) return false;
    return r.stdout.trim() === 'yes';
  } catch {
    return false;
  }
}

// Cached remote-capability check. First call per host costs one ssh probe;
// subsequent calls (same process or fresh process) read the on-disk cache.
// Short-circuits to false if local zstd is missing — nothing to negotiate.
export async function hostHasZstd(address, hostName) {
  if (!localHasZstd()) return false;
  const cached = loadCache(hostName);
  if (cached && typeof cached.zstd === 'boolean') return cached.zstd;
  const ok = await probeRemoteZstd(address);
  saveCache(hostName, {zstd: ok, probedAt: new Date().toISOString()});
  return ok;
}

// Force-probe + cache refresh. Used by `playbash doctor` to warm the cache
// proactively and to catch post-install capability changes. Ignores any
// existing cache entry.
export async function refreshHostZstd(address, hostName) {
  if (!localHasZstd()) {
    saveCache(hostName, {zstd: false, probedAt: new Date().toISOString(), note: 'local zstd missing'});
    return false;
  }
  const ok = await probeRemoteZstd(address);
  saveCache(hostName, {zstd: ok, probedAt: new Date().toISOString()});
  return ok;
}
