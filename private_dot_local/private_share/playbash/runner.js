// share/playbash/runner.js — playbook execution machinery.
//
// Everything that actually spawns a child process and surfaces its output
// to the user lives here:
//
//   - ACTIVE_CHILDREN registry + SIGINT/SIGTERM/SIGHUP handlers (top-level
//     side effect of importing this module — installs once per process).
//   - probeConnectivity: parallel preflight ssh ping for offline detection.
//   - buildRemoteCommand / buildExecCommand: ssh command line builders.
//   - The stuck-on-input detector (regex over recent output + idle watchdog).
//   - runHost: spawn one playbook child, tee its output to a log, fetch
//     and parse the sidecar after exit.
//   - runHostSingle: single-host wrapper around runHost with a Rectangle.
//   - runRemote: single-host remote run (managed or staged).
//   - runLocally: single-host --self run as a direct child.
//   - runFanout: multi-host parallel runs through the StatusBoard.
//   - validateCustomPlaybookPath: slash-convention path validator.
//   - expandTemplate: tiny per-host template substitution.
//
// The dispatcher in executable_playbash imports {runRemote, runLocally,
// runFanout, probeConnectivity, validateCustomPlaybookPath, expandTemplate}.

import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {createWriteStream, existsSync, mkdirSync, readFileSync, statSync, unlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

import {
  COLOR,
  HostSlot,
  Rectangle,
  StatusBoard,
  buildStatusLine,
  sanitizeForRect,
} from './render.js';
import {isSelfAddress} from './inventory.js';
import {
  aggregateEvents,
  parseSidecar,
  renderAggregated,
  renderSummary,
} from './sidecar.js';
import {
  STAGING_DIR,
  WRAPPER_MANAGED,
  ensureWrapper,
  sshRun,
  stagePlaybookDir,
  stagePlaybookFiles,
} from './staging.js';
import {LOG_DIR, PLAYBOOK_DIR, PLAYBOOK_PREFIX} from './paths.js';

// --- die ---
//
// Local die() so the runner module doesn't need to import the entry
// point's helper. Same shape: stderr + exit. Used for unrecoverable
// validation failures inside single-host paths.
function die(msg, code = 2) {
  process.stderr.write(`playbash: ${msg}\n`);
  process.exit(code);
}

// --- global child registry + cleanup on signals ---
//
// Every spawn that owns a process group (detached:true) registers itself
// here so a top-level SIGINT/SIGTERM/SIGHUP can kill the entire group
// before the runner exits. Without this, Ctrl+C delivers SIGINT only to
// node — detached children are in a different process group and survive
// as orphans (bash playbook → upd → sudo blocked on a password prompt).
// Verified on macOS: previously a stuck `playbash run daily ... --self`
// followed by Ctrl+C left bash + sudo behind indefinitely.
//
// For ssh-backed runs there is a second cleanup channel needed because
// of how ssh ControlMaster multiplexing works: killing the local ssh
// mux client only sends a channel-close to the master, which keeps the
// underlying TCP connection alive and never tells sshd that anything
// went wrong. The remote sshd-session keeps running, never SIGHUPs the
// wrapper, and the wrapper's POLLHUP/EPIPE detectors never fire either.
// Result: the entire bash → playbook → chezmoi → install-packages →
// doas subtree on the target survives as an orphan, holding state
// locks etc. (Observed against the full Linux fleet 2026-04-11.)
//
// The fix: the wrapper writes its remote PID to stdout as the first
// line (`__playbash_wrap_pid <pid>\n`) before pty.fork. The runner
// parses this preamble out of the per-host stream and stores it in
// REMOTE_KILLABLE keyed by the local ssh child PID. On signal cleanup,
// the runner sends `ssh host kill -TERM <remote-pid>` over a *fresh*
// channel — the master happily accepts new channels even when an old
// one is stuck — which delivers SIGTERM directly to the orphaned
// wrapper. The wrapper's signal handler then killpgs its bash subtree
// the way it was always supposed to.
const ACTIVE_CHILDREN = new Set();
const REMOTE_KILLABLE = new Map(); // local ssh pid → {address, remotePid}

export function registerChild(child) {
  if (!child || !child.pid) return;
  ACTIVE_CHILDREN.add(child);
  child.once('close', () => {
    ACTIVE_CHILDREN.delete(child);
    REMOTE_KILLABLE.delete(child.pid);
  });
}

// Mark a local ssh child as having a remote wrapper that needs to be
// killed via a fresh ssh channel on cleanup. Called by makeRemoteChild
// at spawn time; the remote PID is filled in later when the wrapper's
// preamble line lands in the chunk handler.
function trackRemoteWrapper(child, address) {
  if (!child || !child.pid) return;
  REMOTE_KILLABLE.set(child.pid, {address, remotePid: null});
}

// Called from runHost's chunk handler once the `__playbash_wrap_pid N`
// line has been parsed out of the head of the stream.
function recordRemoteWrapperPid(localPid, remotePid) {
  const entry = REMOTE_KILLABLE.get(localPid);
  if (entry) entry.remotePid = remotePid;
}

function killAllChildren(sig) {
  for (const child of ACTIVE_CHILDREN) {
    try {
      process.kill(-child.pid, sig);
    } catch {
      try {
        child.kill(sig);
      } catch {}
    }
  }
}

// Send a kill to the remote wrapper via a fresh ssh channel. Returns a
// promise that resolves when the kill completes or after a 4-second
// timeout (whichever comes first). Never throws — best-effort cleanup.
function killRemoteWrapper(address, remotePid) {
  return new Promise(resolve => {
    let done = false;
    const finish = () => { if (!done) { done = true; resolve(); } };
    let proc;
    try {
      proc = spawn('ssh', [
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=3',
        address, '--',
        // SIGTERM, give the wrapper half a second to killpg its subtree
        // and exit, then SIGKILL whatever's left.
        `kill -TERM ${remotePid} 2>/dev/null; sleep 0.5; kill -KILL ${remotePid} 2>/dev/null; true`,
      ], {stdio: ['ignore', 'ignore', 'ignore']});
    } catch {
      finish();
      return;
    }
    proc.on('error', finish);
    proc.on('close', finish);
    setTimeout(() => {
      try { proc.kill('SIGKILL'); } catch {}
      finish();
    }, 4000).unref();
  });
}

let cleaningUp = false;
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => {
    if (cleaningUp) return;
    cleaningUp = true;
    const localCount = ACTIVE_CHILDREN.size;
    const remoteEntries = [...REMOTE_KILLABLE.values()].filter(e => e.remotePid);
    if (localCount > 0 || remoteEntries.length > 0) {
      const parts = [];
      if (localCount > 0) parts.push(`${localCount} local`);
      if (remoteEntries.length > 0) parts.push(`${remoteEntries.length} remote`);
      process.stderr.write(
        `\nplaybash: ${sig} received, terminating ${parts.join(' + ')} child(ren)\n`
      );
    }
    // Local SIGTERM is synchronous and immediate.
    killAllChildren('SIGTERM');
    // Remote kills run in parallel over fresh ssh channels. We give them
    // up to 2 seconds to land before exiting; the per-host kill itself
    // has a 4-second ceiling but we don't want to sit on Ctrl+C waiting
    // for slow networks.
    cleanupAndExit(remoteEntries);
  });
}

async function cleanupAndExit(remoteEntries) {
  if (remoteEntries.length > 0) {
    const kills = remoteEntries.map(e => killRemoteWrapper(e.address, e.remotePid));
    await Promise.race([
      Promise.all(kills),
      new Promise(r => setTimeout(r, 2000)),
    ]);
  } else {
    // Match the old 500ms grace for local-only cleanups.
    await new Promise(r => setTimeout(r, 500));
  }
  process.exit(130);
}

// --- preflight connectivity check ---

// Pre-flight connectivity check. Parallel `ssh -o ConnectTimeout=2 true`
// for every target. Returns {online, offline} arrays of {name, address}.
export async function probeConnectivity(targets) {
  const results = await Promise.all(
    targets.map(async ({name, address}) => {
      try {
        const proc = spawn(
          'ssh',
          [
            '-o',
            'BatchMode=yes',
            '-o',
            'ConnectTimeout=2',
            address,
            '--',
            'true'
          ],
          {stdio: ['ignore', 'ignore', 'ignore']}
        );
        const code = await new Promise(resolve => {
          proc.on('error', () => resolve(255));
          proc.on('close', resolve);
        });
        return {name, address, online: code === 0};
      } catch {
        return {name, address, online: false};
      }
    })
  );
  return {
    online: results
      .filter(r => r.online)
      .map(({name, address}) => ({name, address})),
    offline: results
      .filter(r => !r.online)
      .map(({name, address}) => ({name, address}))
  };
}

// --- Remote PTY wrapper ---
//
// The actual wrapper is a Python script deployed to every managed host
// at ~/.local/libs/playbash-wrap.py via chezmoi. See that file for the
// rationale (PTY allocation, POLLHUP-on-stdout disconnect detection,
// signal-driven killpg cleanup of the bash subtree).
//
// All this function does is build the remote shell command line. The
// playbook path, env-var names, and host name are all values we control
// (host names are validated against [a-zA-Z0-9._-]), so plain string
// interpolation is safe. `exec` so python becomes the direct child of
// sshd's session shell — no intermediate bash -c layer to absorb signals.
function buildRemoteCommand({
  reportPath,
  hostName,
  cols,
  rows,
  playbookPath,
  wrapperPath,
  libs
}) {
  return (
    `LC_ALL=C ` +
    `PLAYBASH_REPORT=${reportPath} ` +
    `PLAYBASH_HOST=${hostName} ` +
    (libs ? `PLAYBASH_LIBS=${libs} ` : '') +
    `COLUMNS=${cols} LINES=${rows} ` +
    `exec python3 -u ${wrapperPath} ${playbookPath}`
  );
}

// Build a remote command line for `playbash exec` — runs an arbitrary
// command through the PTY wrapper, no playbook or sidecar.
function buildExecCommand({cols, rows, command, wrapperPath}) {
  const escaped = command.replace(/'/g, "'\\''");
  return (
    `LC_ALL=C ` +
    `COLUMNS=${cols} LINES=${rows} ` +
    `exec python3 -u ${wrapperPath} bash -c '${escaped}'`
  );
}

// --- Interactive input detection ---
//
// A playbook can hang waiting for input it can't get — most commonly a
// `sudo` password prompt from `chezmoi update` when it needs to install
// a system package. We don't have stdin connected to the remote (and
// don't want to), so the prompt would just sit there forever.
//
// We detect two signals from the captured output stream:
//
//   1. Regex match on a sliding window of recent output. Strong signal,
//      fires immediately, very low false-positive risk because the
//      patterns are specific to known prompts.
//   2. Idle threshold — no chunks received for N seconds while the
//      child is still alive. Weak signal, generous default (90s) to
//      avoid killing legitimate slow operations like apt downloads.
//
// On detection: SIGTERM the child, then SIGKILL after a short grace
// period if it hasn't exited. The host's status word becomes either
// `needs sudo` (regex matched) or `stuck (idle)` (threshold tripped).
// In the summary the host shows as a failure (✗), but with the distinct
// status word so the user can tell it apart from a real non-zero exit.

// Patterns indicating the playbook is hung waiting for input it can't get.
//   - `[sudo] password for X:` — generic Linux sudo
//   - `[sudo: authenticate] Password:` — sudo on some hosts (e.g. think)
//   - `doas (user@host) password:` — opendoas
//   - `Password:` alone — su, ssh, mosh
//   - `Sorry, try again` — sudo's first-failure retry message
//   - `sudo: a terminal is required` — macOS sudo's "no tty" error
//     (different from a prompt, but means the same thing for us:
//     this host needs interactive sudo and we can't help here)
const STDIN_PROMPT_RE =
  /(?:\[sudo[^\]]*\]\s*[Pp]assword|^doas\s*\([^)]*\)\s*password|^Password:\s*$|Sorry, try again|sudo: a terminal is required)/m;
const STDIN_RECENT_BUF_MAX = 4096; // bytes of sliding window for regex
const STDIN_KILL_GRACE_MS = 5000; // SIGTERM → SIGKILL grace period
const TAIL_MAX_LINES = 3; // last N non-blank lines kept for failure context

// Idle threshold in seconds. 0 disables the idle check (regex stays
// active). Default 90s — generous enough that apt downloads and brew
// from-source compiles don't trip it, while still catching real hangs.
function stdinWatchTimeoutMs() {
  const raw = process.env.PLAYBASH_STDIN_WATCH_TIMEOUT;
  if (raw === undefined) return 90 * 1000;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 0) return 90 * 1000;
  return n * 1000;
}

// --- runHost: spawn + capture + sidecar fetch ---

// Spawn the playbook child for one host, tee its raw output to the log
// file, hand sanitized chunks to the caller via `onChunk`, fetch and parse
// the sidecar after exit, and return everything the caller needs to render
// a summary. Does NOT touch the terminal directly (no Rectangle, no
// status line, no exit). Both the single-host wrapper and the fan-out
// runner go through here.
//
// Throws on spawn failure; sidecar fetch errors are non-fatal (logged to
// stderr) and result in an empty event list.
async function runHost({
  playbook,
  hostName,
  makeChild,
  getSidecarText,
  onChunk
}) {
  const cols = process.stdout.columns || 80;
  const rows = process.stdout.rows || 24;

  const logDir = join(LOG_DIR, hostName, playbook);
  mkdirSync(logDir, {recursive: true});
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const logPath = join(logDir, `${stamp}.log`);
  const log = createWriteStream(logPath);

  const start = Date.now();

  // Stuck-on-input detector state. `stuckReason` is null until a signal
  // fires; after that it's 'sudo' or 'idle'.
  let stuckReason = null;
  let recentBuf = '';
  let lastChunkAt = Date.now();
  let idleTimer = null;
  let killTimer = null;
  const idleTimeoutMs = stdinWatchTimeoutMs();

  // Rolling tail of the last N non-blank lines (from stdout AND stderr)
  // for the post-run failure-context display. ANSI codes are stripped
  // before storing so the printed context stays clean.
  const tailBuf = [];
  let tailLineFragment = '';
  const appendToTail = textChunk => {
    const cleaned = textChunk
      .toString('utf8')
      .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '') // strip CSI
      .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '') // strip OSC
      .replace(/\r/g, '');
    tailLineFragment += cleaned;
    const lines = tailLineFragment.split('\n');
    tailLineFragment = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      tailBuf.push(line.trim());
      if (tailBuf.length > TAIL_MAX_LINES) tailBuf.shift();
    }
  };

  let result;
  try {
    result = await new Promise((resolve, reject) => {
      let child;
      try {
        child = makeChild({cols, rows});
      } catch (err) {
        reject(err);
        return;
      }
      registerChild(child);

      const killChild = reason => {
        if (stuckReason) return;
        stuckReason = reason;
        // Send to the entire process group, not just the immediate child.
        // The child may be a shell that's blocked in `wait()` on a
        // foreground subprocess (e.g. `sleep`); SIGTERM to the shell
        // alone can leave the subprocess running and keep the stdout
        // pipe open, which delays our `close` event indefinitely.
        // Killing the group hits the shell AND its descendants.
        // The spawn must use `detached: true` for this to work — see the
        // makeChild call sites.
        const groupKill = sig => {
          try {
            process.kill(-child.pid, sig);
          } catch {
            try {
              child.kill(sig);
            } catch {}
          }
        };
        groupKill('SIGTERM');
        killTimer = setTimeout(() => groupKill('SIGKILL'), STDIN_KILL_GRACE_MS);
      };

      // Idle watchdog. Only armed when the user hasn't disabled it via
      // PLAYBASH_STDIN_WATCH_TIMEOUT=0. Polls at half the threshold,
      // capped at 5s, floored at 1s — so a 90s threshold polls every
      // 5s, a 2s test threshold polls every 1s.
      if (idleTimeoutMs > 0) {
        const pollMs = Math.max(
          1000,
          Math.min(5000, Math.floor(idleTimeoutMs / 2))
        );
        idleTimer = setInterval(() => {
          if (stuckReason) return;
          if (Date.now() - lastChunkAt > idleTimeoutMs) killChild('idle');
        }, pollMs);
      }

      const checkForStuck = chunk => {
        recentBuf = (recentBuf + chunk.toString('utf8')).slice(
          -STDIN_RECENT_BUF_MAX
        );
        if (!stuckReason && STDIN_PROMPT_RE.test(recentBuf)) killChild('sudo');
      };

      // Strip the wrapper's `__playbash_wrap_pid <N>` preamble from the
      // very head of the stdout stream. The preamble exists so the
      // runner can kill the wrapper directly via a fresh ssh channel on
      // Ctrl+C — see the REMOTE_KILLABLE block at the top of this file.
      // Buffer the head until we see a newline OR 256 bytes (whichever
      // comes first); if we matched, store the PID and forward only the
      // post-newline bytes; otherwise forward as-is for backward compat
      // with hosts running the pre-fix wrapper.
      let preambleParsed = false;
      let preambleBuf = Buffer.alloc(0);
      const PREAMBLE_RE = /^__playbash_wrap_pid (\d+)\r?\n/;
      const stripPreamble = chunk => {
        if (preambleParsed) return chunk;
        preambleBuf = Buffer.concat([preambleBuf, chunk]);
        const nl = preambleBuf.indexOf(0x0a);
        if (nl < 0 && preambleBuf.length < 256) return null; // wait for more
        const head = preambleBuf.subarray(0, nl >= 0 ? nl + 1 : preambleBuf.length).toString('utf8');
        const m = head.match(PREAMBLE_RE);
        let rest;
        if (m && nl >= 0) {
          recordRemoteWrapperPid(child.pid, parseInt(m[1], 10));
          rest = preambleBuf.subarray(nl + 1);
        } else {
          rest = preambleBuf;
        }
        preambleParsed = true;
        preambleBuf = null;
        return rest;
      };

      child.stdout.on('data', chunk => {
        const trimmed = stripPreamble(chunk);
        if (trimmed === null) return; // still waiting for the preamble newline
        if (trimmed.length === 0) return;
        // Log gets the trimmed byte stream (forensic copy minus the
        // wrapper's preamble line). The display path gets the sanitized
        // version so terminal queries from remote tools cannot reach
        // the user's terminal regardless of mode.
        log.write(trimmed);
        if (onChunk) onChunk(sanitizeForRect(trimmed));

        lastChunkAt = Date.now();
        appendToTail(trimmed);
        checkForStuck(trimmed);
      });
      child.stderr.on('data', chunk => {
        log.write(chunk);
        // stderr does not feed the live display (rectangle / status board)
        // but it does feed the failure-context tail and the stuck-on-input
        // detector. macOS sudo writes its "a terminal is required" error
        // to stderr only — without this, the local --self path would
        // miss it entirely.
        lastChunkAt = Date.now();
        appendToTail(chunk);
        checkForStuck(chunk);
      });
      child.on('error', reject);
      child.on('close', (code, signal) => {
        if (idleTimer) clearInterval(idleTimer);
        if (killTimer) clearTimeout(killTimer);
        resolve({code, signal});
      });
    });
  } catch (err) {
    if (idleTimer) clearInterval(idleTimer);
    if (killTimer) clearTimeout(killTimer);
    await new Promise(resolve => log.end(resolve));
    throw new Error(`failed to spawn for ${hostName}: ${err.message}`);
  }

  await new Promise(resolve => log.end(resolve));

  // Flush any trailing partial line into the tail buffer (rare — most
  // stream chunks end on a newline — but matters for processes that die
  // mid-line without a final \n).
  if (tailLineFragment.trim()) {
    tailBuf.push(tailLineFragment.trim());
    if (tailBuf.length > TAIL_MAX_LINES) tailBuf.shift();
  }

  let events = [];
  try {
    const text = await getSidecarText();
    events = parseSidecar(text);
  } catch (err) {
    process.stderr.write(
      `playbash: failed to fetch sidecar for ${hostName}: ${err.message}\n`
    );
  }

  const elapsedMs = Date.now() - start;
  // A stuck run is treated as a failure regardless of how it exited
  // (the kill we delivered may show as `signal SIGTERM` or as a
  // wait-status from the wrapped script). The status word reflects the
  // detection signal so the user can distinguish "needs sudo" from a
  // genuine non-zero exit.
  const ok = !stuckReason && !result.signal && result.code === 0;
  const statusWord = stuckReason
    ? stuckReason === 'sudo'
      ? 'needs sudo'
      : 'stuck (idle)'
    : result.signal
      ? `signal ${result.signal}`
      : `exit ${result.code}`;

  return {
    result,
    events,
    logPath,
    elapsedMs,
    ok,
    statusWord,
    stuckReason,
    tail: tailBuf
  };
}

// Single-host wrapper around runHost: owns a Rectangle for live output,
// prints the status line and summary, and exits with the host's exit
// code. Used by both the remote and local single-host paths.
async function runHostSingle({
  playbook,
  hostName,
  label,
  rectHeight,
  verbose,
  makeChild,
  getSidecarText
}) {
  const rect = new Rectangle(rectHeight);
  rect.start();

  let summary;
  try {
    summary = await runHost({
      playbook,
      hostName,
      makeChild,
      getSidecarText,
      onChunk: chunk => {
        if (rect.active) rect.feed(chunk);
        else process.stdout.write(chunk);
      }
    });
  } catch (err) {
    rect.finish();
    die(err.message, 1);
  }

  rect.finish();

  const elapsed = (summary.elapsedMs / 1000).toFixed(1);
  process.stderr.write(
    buildStatusLine({
      ok: summary.ok,
      hostName,
      playbook,
      label,
      status: summary.statusWord,
      elapsed
    }) + '\n'
  );
  renderSummary(summary.events, {verbose});
  if (!summary.ok) {
    // Tail (last few non-blank output lines) gives the user the
    // actionable bit without making them open the log file.
    renderFailureTail(summary.tail);
    // Log path only on failure — when the run is fine, you don't reach
    // for the log; when it failed, you do. `playbash log` finds any past
    // run regardless.
    process.stderr.write(`  ${COLOR.dim}↳ ${summary.logPath}${COLOR.reset}\n`);
  }

  // Skip if a signal handler is already cleaning up — its async cleanup
  // will call process.exit(130) once the remote-kill ssh subprocesses
  // have had a chance to deliver their commands. Without this guard,
  // our normal exit could race with cleanup and cut it short.
  if (!cleaningUp) process.exit(summary.result.code ?? 1);
}

// Render the captured tail of output (last few non-blank lines) under a
// failed host's status line. Truncates each line to terminal width minus
// the indent so it doesn't wrap and break the surrounding layout.
function renderFailureTail(tail) {
  if (!tail || tail.length === 0) return;
  const cols = process.stderr.columns || process.stdout.columns || 80;
  const indent = '  … ';
  const max = Math.max(20, cols - indent.length);
  for (const line of tail) {
    let truncated = line;
    if (truncated.length > max) truncated = truncated.slice(0, max - 1) + '…';
    process.stderr.write(`${COLOR.dim}${indent}${truncated}${COLOR.reset}\n`);
  }
}

// --- shared utilities ---

// Tiny per-host template substitution. Today only `{host}` is used, but
// the regex form is general so future variables can slot in.
export function expandTemplate(template, vars) {
  return template.replace(/\{(\w+)\}/g, (m, key) => vars[key] ?? m);
}

// Validate a custom playbook path (slash convention). Returns 'file' or
// 'dir' on success, throws Error with a clear message on failure. The
// caller decides whether to die() or mark a single host as failed —
// fanout needs the latter so a malformed templated path doesn't kill
// in-flight runs on other hosts.
//
// File case: path must exist and be a regular file. The staging code
// chmods the uploaded copy +x on the remote, so a non-executable source
// file is fine — same as today.
//
// Directory case: must contain main.sh as the entry point, and main.sh
// must be a regular executable file. We require the executable bit on
// purpose so the playbook is "runnable by hand" inside the dir for
// debugging — same property the design doc calls out for single files.
export function validateCustomPlaybookPath(path) {
  if (!existsSync(path)) throw new Error(`script not found: ${path}`);
  const stats = statSync(path);
  if (stats.isDirectory()) {
    const entry = join(path, 'main.sh');
    if (!existsSync(entry)) {
      throw new Error(`directory playbook ${path} has no main.sh entry point`);
    }
    const entryStats = statSync(entry);
    if (!entryStats.isFile()) {
      throw new Error(`${entry} is not a regular file`);
    }
    if ((entryStats.mode & 0o111) === 0) {
      throw new Error(`${entry} must be executable (run: chmod +x ${entry})`);
    }
    return 'dir';
  }
  if (!stats.isFile()) {
    throw new Error(`${path} is not a regular file or directory`);
  }
  return 'file';
}

// --- shared spawn / job-prep helpers ---
//
// runRemote, runLocally, and runFanout's per-host launcher all build the
// same shapes: a "remote job" (wrapper path + playbook path + libs path,
// for ssh-backed runs) or a "local job" (childCmd + childArgs + env, for
// --self runs). Before extraction this was ~150 lines of duplication.
//
// Each helper either returns a value or throws Error. The caller decides
// whether to die() (single-host paths) or mark a per-host failure
// (fan-out path) — neither helper does any output of its own.

const SSH_BASE_ARGS = ['-o', 'BatchMode=yes'];
const CHILD_SPAWN_OPTS = {
  stdio: ['ignore', 'pipe', 'pipe'],
  detached: true // own process group so killChild can group-kill
};

// Build a fresh per-run sidecar report path. baseDir is `/tmp` for the
// remote case (works on every Unix we support without thinking about
// $TMPDIR) and `tmpdir()` for the operator-side --self case.
function makeReportPath(baseDir) {
  return `${baseDir}/playbash-report-${randomBytes(8).toString('hex')}.jsonl`;
}

// Build the wrapper/playbook/libs triple for an ssh-backed run. Throws on
// validation or staging failure; the caller wraps in try/catch and either
// die()s (single-host) or marks the host as a per-host failure (fan-out).
//
//   managed=true   → use chezmoi-deployed paths, no staging
//   playbook=null  → exec mode: stage the wrapper alone via ensureWrapper
//   playbook=set   → playbook mode: stage wrapper + helper + playbook (or
//                    directory tree) via stagePlaybook*
async function prepareRemoteJob({playbook, customPath, hostName, address, managed}) {
  if (managed) {
    return {
      wrapperPath: WRAPPER_MANAGED,
      playbookPath: playbook ? `~/.local/bin/playbash-${playbook}` : undefined,
      libs: null
    };
  }
  if (!playbook) {
    return {
      wrapperPath: await ensureWrapper(address, hostName),
      playbookPath: undefined,
      libs: null
    };
  }
  const resolvedPath = customPath ? expandTemplate(customPath, {host: hostName}) : null;
  let kind = 'file';
  if (resolvedPath) kind = validateCustomPlaybookPath(resolvedPath); // throws
  const remoteName = kind === 'dir'
    ? await stagePlaybookDir(address, hostName, resolvedPath)
    : await stagePlaybookFiles(address, hostName, playbook, resolvedPath);
  return {
    wrapperPath: `${STAGING_DIR}/playbash-wrap.py`,
    playbookPath: `${STAGING_DIR}/${remoteName}`,
    libs: STAGING_DIR
  };
}

// Build the local-job tuple for a --self run: a makeChild closure that
// runHost can call, plus a getSidecarText fetcher. Throws if a named
// playbook does not exist locally — caller decides die vs per-host fail.
function prepareLocalJob({playbook, command, hostName}) {
  if (playbook) {
    const playbookPath = join(PLAYBOOK_DIR, `${PLAYBOOK_PREFIX}${playbook}`);
    if (!existsSync(playbookPath)) {
      throw new Error(`local playbook not found: ${playbookPath}`);
    }
  }
  const reportPath = playbook ? makeReportPath(tmpdir()) : '';
  const childCmd = command ? 'bash' : join(PLAYBOOK_DIR, `${PLAYBOOK_PREFIX}${playbook}`);
  const childArgs = command ? ['-c', command] : [];
  const baseEnv = {...process.env, LC_ALL: 'C'};
  if (playbook) {
    baseEnv.PLAYBASH_REPORT = reportPath;
    baseEnv.PLAYBASH_HOST = hostName;
  }
  return {
    makeChild: ({cols, rows}) => spawn(childCmd, childArgs, {
      ...CHILD_SPAWN_OPTS,
      env: {...baseEnv, COLUMNS: String(cols), LINES: String(rows)}
    }),
    getSidecarText: makeLocalSidecarFetcher(reportPath)
  };
}

// Spawn a remote ssh child running `wrapped` (the full remote command
// line — either a buildRemoteCommand or buildExecCommand result), and
// register it for remote-kill cleanup. The remote PID gets filled in
// later when runHost parses the wrapper's `__playbash_wrap_pid` preamble.
function makeRemoteChild(address, wrapped) {
  const child = spawn('ssh', [...SSH_BASE_ARGS, address, '--', wrapped], CHILD_SPAWN_OPTS);
  trackRemoteWrapper(child, address);
  return child;
}

// Build a "fetch and clean up the remote sidecar file" closure. Returns
// an empty-string fetcher if reportPath is falsy (exec mode, no sidecar).
function makeRemoteSidecarFetcher(address, reportPath) {
  if (!reportPath) return async () => '';
  return async () => {
    const r = await sshRun(address, `cat ${reportPath} 2>/dev/null; rm -f ${reportPath}`);
    return r.stdout;
  };
}

// Build a "read and unlink the local sidecar file" closure. Returns an
// empty-string fetcher if reportPath is falsy (exec mode, no sidecar).
function makeLocalSidecarFetcher(reportPath) {
  if (!reportPath) return async () => '';
  return async () => {
    let text = '';
    try { text = readFileSync(reportPath, 'utf8'); } catch {}
    try { unlinkSync(reportPath); } catch {}
    return text;
  };
}

// --- runRemote / runLocally / runFanout ---

export async function runRemote({
  playbook,
  command,
  customPath,
  hostName,
  address,
  rectHeight,
  verbose,
  managed
}) {
  let job;
  try {
    job = await prepareRemoteJob({playbook, customPath, hostName, address, managed});
  } catch (err) {
    die(err.message);
  }
  const logLabel = playbook || 'exec';
  const reportPath = playbook ? makeReportPath('/tmp') : '';
  await runHostSingle({
    playbook: logLabel,
    hostName,
    rectHeight,
    verbose,
    label: null,
    makeChild: ({cols, rows}) => {
      const wrapped = command
        ? buildExecCommand({cols, rows, command, wrapperPath: job.wrapperPath})
        : buildRemoteCommand({reportPath, hostName, cols, rows, ...job});
      return makeRemoteChild(address, wrapped);
    },
    getSidecarText: makeRemoteSidecarFetcher(address, reportPath)
  });
}

export async function runLocally({playbook, command, hostName, rectHeight, verbose}) {
  let job;
  try {
    job = prepareLocalJob({playbook, command, hostName});
  } catch (err) {
    die(err.message);
  }
  await runHostSingle({
    playbook: playbook || 'exec',
    hostName,
    rectHeight,
    verbose,
    label: '(local)',
    makeChild: job.makeChild,
    getSidecarText: job.getSidecarText
  });
}

// Run a list of targets in parallel through the StatusBoard, then print
// per-host summaries (in input order) and the aggregated section.
// When `transfer` is provided (for put/get), each host runs the simple
// transfer callback instead of the full runHost pipeline.
export async function runFanout({
  playbook,
  command,
  customPath,
  targets,
  rectHeight,
  verbose,
  parallelLimit,
  inventory,
  push,
  offlineNames,
  transfer
}) {
  const logLabel = playbook || transfer?.label || 'exec';
  const effectiveRect = transfer ? 0 : (rectHeight ?? 5);
  const slots = targets.map(t => new HostSlot(t.name, t.address, effectiveRect));
  const board = new StatusBoard(slots, {playbook: logLabel, rectHeight: effectiveRect});
  board.start();

  const launchOne = async slot => {
    if (offlineNames.has(slot.name)) {
      board.hostFinished(slot.name, {
        ok: false, statusWord: 'offline', events: [], logPath: '', elapsedMs: 0
      });
      return;
    }
    board.hostStarted(slot.name);

    // Transfer mode (put/get): simple async callback, no PTY/sidecar/log.
    if (transfer) {
      const start = Date.now();
      try {
        const message = await transfer.fn(slot.name, slot.address);
        const summary = {
          ok: true, statusWord: '', events: [], logPath: '', elapsedMs: Date.now() - start
        };
        if (message) summary.capturedOutput = message;
        board.hostFinished(slot.name, summary);
      } catch (err) {
        board.hostFinished(slot.name, {
          ok: false, statusWord: err.message.slice(0, 60),
          events: [], logPath: '', elapsedMs: Date.now() - start
        });
      }
      return;
    }

    const isSelf = await isSelfAddress(slot.address);
    let makeChild, getSidecarText;

    if (isSelf) {
      let job;
      try {
        job = prepareLocalJob({playbook, command, hostName: slot.name});
      } catch {
        board.hostFinished(slot.name, {
          ok: false, statusWord: 'no script', events: [], logPath: '', elapsedMs: 0
        });
        return;
      }
      makeChild = job.makeChild;
      getSidecarText = job.getSidecarText;
    } else {
      // Per-host template miss is a "skip" (expected — not every host
      // has a `./reports/{host}/`); other validation/staging errors are
      // "fail this host" so other in-flight runs are not affected.
      const resolvedPath = customPath ? expandTemplate(customPath, {host: slot.name}) : null;
      if (resolvedPath && !existsSync(resolvedPath)) {
        board.hostFinished(slot.name, {
          ok: true, statusWord: 'skipped', events: [], logPath: '', elapsedMs: 0
        });
        return;
      }
      const managed = !push && inventory.hosts.has(slot.name);
      let job;
      try {
        job = await prepareRemoteJob({
          playbook, customPath, hostName: slot.name, address: slot.address, managed
        });
      } catch (err) {
        board.hostFinished(slot.name, {
          ok: false, statusWord: err.message.slice(0, 60),
          events: [], logPath: '', elapsedMs: 0
        });
        return;
      }
      const reportPath = playbook ? makeReportPath('/tmp') : '';
      makeChild = ({cols, rows}) => {
        const wrapped = command
          ? buildExecCommand({cols, rows, command, wrapperPath: job.wrapperPath})
          : buildRemoteCommand({reportPath, hostName: slot.name, cols, rows, ...job});
        return makeRemoteChild(slot.address, wrapped);
      };
      getSidecarText = makeRemoteSidecarFetcher(slot.address, reportPath);
    }

    try {
      const capturedChunks = command ? [] : null;
      const summary = await runHost({
        playbook: logLabel,
        hostName: slot.name,
        makeChild,
        getSidecarText,
        onChunk: chunk => {
          board.hostChunk(slot.name, chunk);
          if (capturedChunks) capturedChunks.push(chunk);
        }
      });
      if (capturedChunks) summary.capturedOutput = capturedChunks.join('');
      board.hostFinished(slot.name, summary);
    } catch (err) {
      board.hostFinished(slot.name, {
        ok: false, statusWord: 'spawn err', events: [], logPath: '', elapsedMs: 0
      });
      process.stderr.write(`playbash: ${slot.name}: ${err.message}\n`);
    }
  };

  // Concurrency-limited launcher. parallelLimit === 0 means unlimited.
  const queue = [...slots];
  const inFlight = new Set();
  const limit = parallelLimit > 0 ? parallelLimit : queue.length;
  const launchNext = () => {
    while (queue.length > 0 && inFlight.size < limit) {
      const slot = queue.shift();
      const p = launchOne(slot).finally(() => {
        inFlight.delete(p);
        launchNext();
      });
      inFlight.add(p);
    }
  };
  launchNext();
  while (inFlight.size > 0) {
    await Promise.race(inFlight);
  }

  board.finish();

  // Per-host summary lines, input order.
  let okCount = 0;
  let failCount = 0;
  let offlineCount = 0;
  let skippedCount = 0;
  for (const slot of slots) {
    if (slot.statusWord === 'offline') offlineCount++;
    else if (slot.statusWord === 'skipped') skippedCount++;
    else if (slot.state === 'ok') okCount++;
    else failCount++;
    const elapsed = (slot.elapsedMs / 1000).toFixed(1);
    process.stderr.write(
      buildStatusLine({
        ok: slot.state === 'ok',
        hostName: slot.name,
        playbook: logLabel,
        label: null,
        status: slot.statusWord,
        elapsed
      }) + '\n'
    );
    if (transfer || command) {
      // transfer/exec: show captured output per host
      if (slot.capturedOutput && slot.capturedOutput.trim()) {
        for (const line of slot.capturedOutput.trimEnd().split('\n')) {
          process.stderr.write(`  ${line}\n`);
        }
      }
      if (
        slot.state !== 'ok' &&
        slot.statusWord !== 'offline' &&
        slot.statusWord !== 'skipped'
      ) {
        if (slot.logPath) {
          process.stderr.write(`  ${COLOR.dim}↳ ${slot.logPath}${COLOR.reset}\n`);
        }
      }
    } else {
      renderSummary(slot.events, {verbose});
      if (slot.state !== 'ok') {
        renderFailureTail(slot.tail);
        if (slot.logPath) {
          process.stderr.write(`  ${COLOR.dim}↳ ${slot.logPath}${COLOR.reset}\n`);
        }
      }
    }
  }

  // Footer line + cross-host aggregation.
  const ranSlots = slots.filter(
    s => s.statusWord !== 'offline' && s.statusWord !== 'skipped'
  );
  const totalElapsed =
    ranSlots.length > 0
      ? ((Date.now() - ranSlots[0].startedAt) / 1000).toFixed(1)
      : '0.0';
  const summaryParts = [];
  if (okCount > 0) summaryParts.push(`${okCount} ok`);
  if (failCount > 0)
    summaryParts.push(`${COLOR.bold}${COLOR.red}${failCount} failed${COLOR.reset}`);
  if (skippedCount > 0)
    summaryParts.push(`${COLOR.dim}${skippedCount} skipped${COLOR.reset}`);
  if (offlineCount > 0)
    summaryParts.push(`${COLOR.dim}${offlineCount} offline${COLOR.reset}`);
  process.stderr.write(
    `\n${COLOR.dim}done in ${totalElapsed}s${COLOR.reset} · ${summaryParts.join(', ')}\n`
  );

  renderAggregated(aggregateEvents(slots));

  // Skip if a signal handler is already cleaning up — see runHostSingle.
  if (!cleaningUp) process.exit(failCount > 0 ? 1 : 0);
}
