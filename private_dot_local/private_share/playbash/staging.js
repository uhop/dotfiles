// share/playbash/staging.js — wrapper staging for vanilla (non-chezmoi) hosts.
//
// Ensures playbash-wrap.py exists on a remote host before a run and returns
// its remote path. For chezmoi-managed hosts the wrapper is already deployed
// at ~/.local/libs/playbash-wrap.py; for vanilla hosts it is pushed to
// ~/.cache/playbash-staging/playbash-wrap.py via `cat | ssh`.
//
// Results are cached under ~/.cache/playbash/staging/<hostName>.json, keyed
// by the local wrapper's SHA-256. A `chezmoi apply` that updates the wrapper
// invalidates all caches and triggers re-probe / re-stage on next run.
//
// No user-visible CLI surface — this is substrate for milestones 15, 16, 17.

import {createHash} from 'node:crypto';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';

const WRAPPER_LOCAL   = join(homedir(), '.local', 'libs', 'playbash-wrap.py');
const WRAPPER_MANAGED = '~/.local/libs/playbash-wrap.py';
const WRAPPER_STAGED  = '~/.cache/playbash-staging/playbash-wrap.py';
const CACHE_DIR       = join(homedir(), '.cache', 'playbash', 'staging');

// --- internal helpers ---

// Run a command on a remote host via ssh with BatchMode=yes.
// Returns {code, stdout, stderr}. If `input` is provided it is piped to stdin.
function sshRun(address, remoteCmd, input) {
  return new Promise((resolve, reject) => {
    const proc = spawn('ssh', ['-o', 'BatchMode=yes', address, '--', remoteCmd], {
      stdio: [input != null ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    let stdout = '', stderr = '';
    proc.stdout.on('data', c => (stdout += c));
    proc.stderr.on('data', c => (stderr += c));
    proc.on('error', reject);
    proc.on('close', code => resolve({code, stdout, stderr}));
    if (input != null) {
      proc.stdin.write(input);
      proc.stdin.end();
    }
  });
}

// SHA-256 of the local wrapper, memoized for the process lifetime.
let _sha = null;
function wrapperSha() {
  if (_sha) return _sha;
  _sha = createHash('sha256').update(readFileSync(WRAPPER_LOCAL)).digest('hex');
  return _sha;
}

function loadCache(hostName) {
  try {
    return JSON.parse(readFileSync(join(CACHE_DIR, `${hostName}.json`), 'utf8'));
  } catch {
    return null;
  }
}

function saveCache(hostName, entry) {
  mkdirSync(CACHE_DIR, {recursive: true});
  writeFileSync(join(CACHE_DIR, `${hostName}.json`), JSON.stringify(entry) + '\n');
}

// Push the local wrapper to the remote staging directory. Throws on failure.
async function stageWrapper(address, hostName) {
  const content = readFileSync(WRAPPER_LOCAL);
  const r = await sshRun(
    address,
    `mkdir -p ~/.cache/playbash-staging && cat > ${WRAPPER_STAGED} && chmod +x ${WRAPPER_STAGED}`,
    content,
  );
  if (r.code !== 0) {
    throw new Error(`failed to stage wrapper on ${hostName}: ${r.stderr.trim() || `exit ${r.code}`}`);
  }
}

// --- public API ---

// Ensure the Python PTY wrapper is present on `address` and return its
// remote path. Uses a local file cache keyed by the wrapper's SHA-256 so
// repeat runs against the same host are free (zero ssh calls).
//
// Detection strategy:
//   - If the inventory entry has `managed: false`, the host is treated as
//     vanilla — the wrapper is staged without probing.
//   - Otherwise, the managed path is probed first. On probe failure the
//     wrapper is staged automatically.
//
// `inventory` may be null/undefined (e.g. when the target was a bare
// ssh-config alias with no inventory entry). In that case, probe is used.
export async function ensureWrapper(address, hostName, inventory) {
  const sha = wrapperSha();

  const cached = loadCache(hostName);
  if (cached && cached.wrapperSha === sha) return cached.remotePath;

  // Check for explicit `managed: false` in the inventory entry.
  const entry = inventory?.hosts?.get(hostName);
  if (entry?.managed === false) {
    await stageWrapper(address, hostName);
    saveCache(hostName, {wrapperSha: sha, remotePath: WRAPPER_STAGED});
    return WRAPPER_STAGED;
  }

  // Probe the chezmoi-managed path.
  const probe = await sshRun(address, `test -f ${WRAPPER_MANAGED}`);
  if (probe.code === 0) {
    saveCache(hostName, {wrapperSha: sha, remotePath: WRAPPER_MANAGED});
    return WRAPPER_MANAGED;
  }

  // Probe failed — stage the wrapper.
  await stageWrapper(address, hostName);
  saveCache(hostName, {wrapperSha: sha, remotePath: WRAPPER_STAGED});
  return WRAPPER_STAGED;
}
