// share/playbash/staging.js — file staging for vanilla (non-chezmoi) hosts.
//
// Ensures playbash-wrap.py exists on a remote host before a run and returns
// its remote path. For chezmoi-managed hosts the wrapper is already deployed
// at ~/.local/libs/playbash-wrap.py; for vanilla hosts it is pushed to
// ~/.cache/playbash-staging/playbash-wrap.py via `cat | ssh`.
//
// For `run`/`debug` on vanilla hosts, also stages playbash.sh (helper
// library) and the playbook script into the same staging dir, so the
// playbook can source its helper via PLAYBASH_LIBS=<staging>.
//
// The caller decides managed vs. upload based on inventory membership:
// hosts in the inventory are managed (wrapper + playbooks pre-deployed via
// chezmoi); bare SSH aliases are vanilla and get everything staged.
// Wrapper staging is cached under ~/.cache/playbash/staging/<hostName>.json,
// keyed by the local wrapper's SHA-256. For playbook files, a remote SHA-256
// probe (one ssh round trip) replaces local caching — the remote is the
// source of truth, so deleted or corrupted files are re-uploaded on next run.

import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';

const WRAPPER_LOCAL   = join(homedir(), '.local', 'libs', 'playbash-wrap.py');
const HELPER_LOCAL    = join(homedir(), '.local', 'libs', 'playbash.sh');
const PLAYBOOK_DIR   = join(homedir(), '.local', 'bin');
export const WRAPPER_MANAGED = '~/.local/libs/playbash-wrap.py';
export const STAGING_DIR = '~/.cache/playbash-staging';
const WRAPPER_STAGED  = `${STAGING_DIR}/playbash-wrap.py`;
const CACHE_DIR       = join(homedir(), '.cache', 'playbash', 'staging');

// --- ssh helpers ---

// Run a command on a remote host via ssh with BatchMode=yes.
// Returns {code, stdout, stderr}. If `input` is provided it is piped to stdin.
// Exported for use by put/get transfer commands.
export function sshRun(address, remoteCmd, input) {
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

function fileSha(content) {
  return createHash('sha256').update(content).digest('hex');
}

// SHA-256 of the local wrapper, memoized for the process lifetime.
let _sha = null;
function wrapperSha() {
  if (_sha) return _sha;
  _sha = fileSha(readFileSync(WRAPPER_LOCAL));
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
    `mkdir -p ${STAGING_DIR} && cat > ${WRAPPER_STAGED} && chmod +x ${WRAPPER_STAGED}`,
    content,
  );
  if (r.code !== 0) {
    throw new Error(`failed to stage wrapper on ${hostName}: ${r.stderr.trim() || `exit ${r.code}`}`);
  }
}

// Probe the remote staging dir for existing files and their SHA-256 hashes.
// Returns a Map<filename, sha256hex>. Uses a Python one-liner (Python 3.3+
// is already a hard requirement for the PTY wrapper).
async function probeRemoteShas(address, remotePaths) {
  const pyScript = [
    'import hashlib,sys',
    'for f in sys.argv[1:]:',
    ' try:print(hashlib.sha256(open(f,"rb").read()).hexdigest(),f.rsplit("/",1)[-1])',
    ' except:pass',
  ].join('\n');
  const r = await sshRun(address, `python3 -c '${pyScript}' ${remotePaths.join(' ')}`);
  const shas = new Map();
  if (r.code === 0) {
    for (const line of r.stdout.split('\n')) {
      if (!line.trim()) continue;
      const [sha, name] = line.trim().split(/\s+/, 2);
      if (sha && name) shas.set(name, sha);
    }
  }
  return shas;
}

// Ensure the staging dir on the remote has up-to-date copies of the wrapper,
// helper library, and playbook script. One SSH probe computes SHA-256 of
// existing remote files; only files with a mismatched or missing hash are
// re-uploaded (parallel `cat | ssh` calls, one per file). No local cache —
// the remote is the source of truth.
export async function stagePlaybookFiles(address, hostName, playbookName) {
  const wrapperContent = readFileSync(WRAPPER_LOCAL);
  const helperContent = readFileSync(HELPER_LOCAL);
  const playbookLocalPath = join(PLAYBOOK_DIR, `playbash-${playbookName}`);
  if (!existsSync(playbookLocalPath)) {
    throw new Error(`playbook not found locally: ${playbookLocalPath}`);
  }
  const playbookContent = readFileSync(playbookLocalPath);

  const files = [
    {name: 'playbash-wrap.py', content: wrapperContent, sha: fileSha(wrapperContent), executable: true},
    {name: 'playbash.sh', content: helperContent, sha: fileSha(helperContent), executable: false},
    {name: `playbash-${playbookName}`, content: playbookContent, sha: fileSha(playbookContent), executable: true},
  ];

  // Probe: one SSH round trip to hash all staged files on the remote.
  const remoteShas = await probeRemoteShas(
    address,
    files.map(f => `${STAGING_DIR}/${f.name}`),
  );

  // Upload only files whose remote SHA doesn't match the local copy.
  const needed = files.filter(f => remoteShas.get(f.name) !== f.sha);
  if (needed.length === 0) return;

  const stageOne = ({name, content, executable}) => {
    const cmd = executable
      ? `mkdir -p ${STAGING_DIR} && cat > ${STAGING_DIR}/${name} && chmod +x ${STAGING_DIR}/${name}`
      : `mkdir -p ${STAGING_DIR} && cat > ${STAGING_DIR}/${name}`;
    return sshRun(address, cmd, content);
  };

  const results = await Promise.all(needed.map(stageOne));

  for (let i = 0; i < results.length; i++) {
    if (results[i].code !== 0) {
      throw new Error(
        `failed to stage ${needed[i].name} on ${hostName}: ${results[i].stderr.trim() || `exit ${results[i].code}`}`,
      );
    }
  }
}

// --- public API ---

// Ensure the Python PTY wrapper is staged at STAGING_DIR on the remote.
// Used by `exec` on non-inventory hosts (no playbook to stage, just the
// wrapper). For playbook runs, stagePlaybookFiles() handles the wrapper
// as part of its probe. Returns the remote wrapper path (always STAGED).
// Cached by wrapper SHA-256 so repeat runs cost zero ssh calls.
export async function ensureWrapper(address, hostName) {
  const sha = wrapperSha();
  const cached = loadCache(hostName);
  if (cached && cached.wrapperSha === sha && cached.remotePath === WRAPPER_STAGED) {
    return WRAPPER_STAGED;
  }
  await stageWrapper(address, hostName);
  saveCache(hostName, {wrapperSha: sha, remotePath: WRAPPER_STAGED});
  return WRAPPER_STAGED;
}
