// share/playbash/staging.js — file staging for vanilla (non-chezmoi) hosts.
//
// Ensures playbash-wrap.py exists on a remote host before a run and returns
// its remote path. For chezmoi-managed hosts the wrapper is already deployed
// at ~/.local/libs/playbash-wrap.py; for vanilla hosts it is pushed to
// ~/.cache/playbash-staging/playbash-wrap.py via `cat | ssh`.
//
// For `run`/`debug` on vanilla hosts, also stages playbash.sh (helper
// library) and the playbook into the same staging dir, so the playbook can
// source its helper via PLAYBASH_LIBS=<staging>. Two playbook shapes are
// supported: a single file (uploaded as STAGING_DIR/<filename>), and a
// directory tree (tar'd and extracted into STAGING_DIR/<dirname>/, with
// main.sh as the entry point).
//
// The caller decides managed vs. upload based on inventory membership:
// hosts in the inventory are managed (wrapper + playbooks pre-deployed via
// chezmoi); bare SSH aliases are vanilla and get everything staged.
// Wrapper staging is cached under ~/.cache/playbash/staging/<hostName>.json,
// keyed by the local wrapper's SHA-256. For playbook files, a remote SHA-256
// probe (one ssh round trip) replaces local caching — the remote is the
// source of truth, so deleted or corrupted files are re-uploaded on next run.
// Directory playbooks always re-tar the whole tree (small dirs, simple model).

import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {basename as pathBasename, join} from 'node:path';
import {spawn} from 'node:child_process';

import {STAGING_DIR} from './paths.js';
import {registerChild} from './runner.js';
import {shellQuote} from './shell-escape.js';

const WRAPPER_LOCAL   = join(homedir(), '.local', 'libs', 'playbash-wrap.py');
const HELPER_LOCAL    = join(homedir(), '.local', 'libs', 'playbash.sh');
const PLAYBOOK_DIR   = join(homedir(), '.local', 'bin');
const WRAPPER_STAGED  = `${STAGING_DIR}/playbash-wrap.py`;
const CACHE_DIR       = join(homedir(), '.cache', 'playbash', 'staging');

// Directory playbook names go into shell command lines (rm -rf, mkdir, tar
// extract). Restrict to a safe character set, and reserve names that would
// collide with the staged libraries at the staging root.
const SAFE_DIR_NAME_RE = /^[a-zA-Z0-9._-]+$/;
const RESERVED_DIR_NAMES = new Set(['playbash-wrap.py', 'playbash.sh']);

// --- ssh helpers ---

// Run a command on a remote host via ssh with BatchMode=yes.
// Returns {code, stdout, stderr}. Options:
//   input — Buffer/string piped to stdin (default: no stdin)
//   raw   — return stdout as a Buffer instead of a string (for binary data)
export function sshRun(address, remoteCmd, {input, raw} = {}) {
  return new Promise((resolve, reject) => {
    const proc = spawn('ssh', ['-o', 'BatchMode=yes', address, '--', remoteCmd], {
      stdio: [input != null ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    // Register with the runner's child registry so a SIGINT during
    // staging work kills in-flight ssh children instead of leaving them
    // orphaned. The children are not detached, so killAllChildren's
    // process-group kill falls through to the per-child `child.kill()`
    // fallback — which is what we want for short-lived non-PTY ssh.
    registerChild(proc);
    const chunks = [];
    let stderr = '';
    proc.stdout.on('data', c => chunks.push(c));
    proc.stderr.on('data', c => (stderr += c));
    proc.on('error', reject);
    proc.on('close', code => {
      const buf = Buffer.concat(chunks);
      resolve({code, stdout: raw ? buf : buf.toString(), stderr});
    });
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
    {input: content},
  );
  if (r.code !== 0) {
    throw new Error(`failed to stage wrapper on ${hostName}: ${r.stderr.trim() || `exit ${r.code}`}`);
  }
}

// Probe the remote staging dir for existing files and their SHA-256 hashes.
// Returns a Map<filename, sha256hex>. Uses a Python one-liner (Python 3.3+
// is already a hard requirement for the PTY wrapper).
//
// Takes plain filenames (not full paths) so this function owns the
// STAGING_DIR-prefix construction and the shell-quoting of the untrusted
// basename component. Library files (playbash-wrap.py, playbash.sh) and
// managed playbook names are safe; single-file custom playbooks upstream
// come from pathBasename of operator input and may contain spaces or
// metacharacters — shellQuote handles them.
async function probeRemoteShas(address, fileNames) {
  const pyScript = [
    'import hashlib,sys',
    'for f in sys.argv[1:]:',
    ' try:print(hashlib.sha256(open(f,"rb").read()).hexdigest(),f.rsplit("/",1)[-1])',
    ' except:pass',
  ].join('\n');
  const quoted = fileNames
    .map(n => `${STAGING_DIR}/${shellQuote(n)}`)
    .join(' ');
  const r = await sshRun(address, `python3 -c '${pyScript}' ${quoted}`);
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

// Probe + upload a list of files into STAGING_DIR. Each file is `{name,
// content, sha, executable}`. One SSH round trip hashes the existing remote
// copies; only mismatched or missing files are re-uploaded (parallel
// `cat | ssh` calls, one per file). No local cache — the remote is the
// source of truth, so deleted or corrupted files are re-uploaded next run.
async function uploadStagedFiles(address, hostName, files) {
  const remoteShas = await probeRemoteShas(
    address,
    files.map(f => f.name),
  );
  const needed = files.filter(f => remoteShas.get(f.name) !== f.sha);
  if (needed.length === 0) return;

  const stageOne = ({name, content, executable}) => {
    // `name` may be pathBasename(customLocalPath) for single-file custom
    // playbooks and can contain spaces/quotes/metacharacters — quote it
    // against the trusted STAGING_DIR prefix. STAGING_DIR itself starts
    // with `~` and must stay unquoted so the remote shell expands home.
    const qName = shellQuote(name);
    const cmd = executable
      ? `mkdir -p ${STAGING_DIR} && cat > ${STAGING_DIR}/${qName} && chmod +x ${STAGING_DIR}/${qName}`
      : `mkdir -p ${STAGING_DIR} && cat > ${STAGING_DIR}/${qName}`;
    return sshRun(address, cmd, {input: content});
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

// Build the wrapper + helper file descriptors for upload. Both live at the
// staging root and are shared across every staged playbook on the host.
function libFileDescriptors() {
  const wrapperContent = readFileSync(WRAPPER_LOCAL);
  const helperContent = readFileSync(HELPER_LOCAL);
  return [
    {name: 'playbash-wrap.py', content: wrapperContent, sha: fileSha(wrapperContent), executable: true},
    {name: 'playbash.sh',      content: helperContent,  sha: fileSha(helperContent),  executable: false},
  ];
}

// Ensure the staging dir on the remote has up-to-date copies of the wrapper,
// helper library, and a single-file playbook script. `customLocalPath`
// overrides the default playbook location for custom scripts (paths
// containing /). Returns the remote filename used in the staging dir so the
// caller can construct the full remote path.
export async function stagePlaybookFiles(address, hostName, playbookName, customLocalPath) {
  const playbookLocalPath = customLocalPath || join(PLAYBOOK_DIR, `playbash-${playbookName}`);
  if (!existsSync(playbookLocalPath)) {
    throw new Error(`playbook not found locally: ${playbookLocalPath}`);
  }
  const playbookContent = readFileSync(playbookLocalPath);
  const remoteName = customLocalPath ? pathBasename(customLocalPath) : `playbash-${playbookName}`;

  const files = [
    ...libFileDescriptors(),
    {name: remoteName, content: playbookContent, sha: fileSha(playbookContent), executable: true},
  ];
  await uploadStagedFiles(address, hostName, files);
  return remoteName;
}

// Stage a directory tree as a playbook bundle. The directory must contain
// an executable main.sh entry point — the caller is responsible for
// validation (the runner's validateCustomPlaybookPath helper does this).
//
// The whole tree is tar'd and extracted into ~/.cache/playbash-staging/<dir>/
// (rm -rf'd first so stale files from a previous push don't linger). The
// wrapper + helper library are staged as siblings at the staging root, so
// the playbook can source $PLAYBASH_LIBS/playbash.sh unchanged. Helpers
// inside the directory are reachable via $(dirname "$0") from main.sh.
//
// Returns the remote entry path relative to STAGING_DIR (e.g. "mydir/main.sh")
// — same shape as stagePlaybookFiles, so the runner treats both uniformly.
export async function stagePlaybookDir(address, hostName, localDir) {
  const dirName = pathBasename(localDir.replace(/\/+$/, ''));
  if (!dirName || !SAFE_DIR_NAME_RE.test(dirName)) {
    throw new Error(
      `invalid playbook directory name "${dirName}" — must match [a-zA-Z0-9._-]+`,
    );
  }
  if (RESERVED_DIR_NAMES.has(dirName)) {
    throw new Error(
      `playbook directory name "${dirName}" conflicts with a staged library file`,
    );
  }

  // Stage wrapper + helper at the staging root (probe + conditional upload).
  await uploadStagedFiles(address, hostName, libFileDescriptors());

  // Tar the directory contents (the . at the end captures dotfiles too) and
  // upload + extract in one ssh call. Wipe any previous stage of the same
  // dir so stale files from a previous push don't linger.
  const tarBuf = await new Promise((resolve, reject) => {
    const chunks = [];
    const p = spawn('tar', ['cf', '-', '-C', localDir, '.'], {stdio: ['ignore', 'pipe', 'pipe']});
    p.stdout.on('data', c => chunks.push(c));
    p.on('error', reject);
    p.on('close', code =>
      code === 0 ? resolve(Buffer.concat(chunks)) : reject(new Error(`tar exit ${code}`)),
    );
  });

  const remoteDir = `${STAGING_DIR}/${dirName}`;
  const cmd =
    `mkdir -p ${STAGING_DIR} && rm -rf ${remoteDir} && ` +
    `mkdir -p ${remoteDir} && tar xf - -C ${remoteDir}`;
  const r = await sshRun(address, cmd, {input: tarBuf});
  if (r.code !== 0) {
    throw new Error(
      `failed to stage directory ${localDir} on ${hostName}: ${r.stderr.trim() || `exit ${r.code}`}`,
    );
  }

  return `${dirName}/main.sh`;
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
