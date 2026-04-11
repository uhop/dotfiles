// share/playbash/ssh-config.js — minimal ssh_config(5) parser.
//
// Walks ~/.ssh/config plus any Include'd files and returns the set of
// literal Host names defined in them. Wildcard patterns (`*`, `?`) are
// skipped — they aren't useful as completion candidates and would need a
// known universe to match against.
//
// Used by:
//   - doctor.js: warn on inventory hosts that have no matching Host entry
//   - executable_playbash __complete-targets: enrich tab completion with
//     ssh-config aliases that aren't in inventory
//   - executable_playbash cmdHosts: list ssh-config hosts that aren't in
//     inventory under their own section in `playbash hosts`
//
// Pure: no I/O beyond reading files. Throws nothing — files that fail to
// read or directories that fail to list silently contribute zero hosts.
// The caller can do nothing useful with such errors mid-completion or
// mid-doctor anyway.

import {existsSync, readFileSync, readdirSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

const SSH_DIR    = join(homedir(), '.ssh');
const SSH_CONFIG = join(SSH_DIR, 'config');

// Expand an Include directive's argument into concrete file paths.
// Relative paths are resolved against ~/.ssh per ssh_config(5). The
// common `dir/*` glob form is handled inline; other glob patterns are
// not expanded (we'd need a glob lib for full coverage and the simple
// case is what every real ssh config uses).
function expandInclude(pattern) {
  const absPattern = pattern.startsWith('/') ? pattern : join(SSH_DIR, pattern);
  if (absPattern.endsWith('/*')) {
    const dir = absPattern.slice(0, -2);
    try {
      return readdirSync(dir)
        .map(f => join(dir, f))
        .filter(p => {
          try { return statSync(p).isFile(); } catch { return false; }
        });
    } catch { return []; }
  }
  return existsSync(absPattern) ? [absPattern] : [];
}

// Walk ~/.ssh/config plus Include'd files, collect literal `Host` names.
// Returns a Set<string>. Wildcard patterns are skipped.
export function parseHostNames() {
  const out = new Set();
  const visited = new Set();

  const walk = path => {
    if (visited.has(path)) return;
    visited.add(path);
    let text;
    try { text = readFileSync(path, 'utf8'); } catch { return; }
    for (const rawLine of text.split('\n')) {
      const t = rawLine.trim();
      if (!t || t.startsWith('#')) continue;
      const m = t.match(/^(Host|Include)\s+(.+)$/i);
      if (!m) continue;
      const key = m[1].toLowerCase();
      const value = m[2].trim();
      if (key === 'host') {
        for (const name of value.split(/\s+/)) {
          if (name && !name.includes('*') && !name.includes('?')) {
            out.add(name);
          }
        }
      } else if (key === 'include') {
        for (const pat of value.split(/\s+/)) {
          for (const sub of expandInclude(pat)) walk(sub);
        }
      }
    }
  };

  walk(SSH_CONFIG);
  return out;
}
