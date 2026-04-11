// share/playbash/subprocess.js — tiny short-lived-subprocess helper.
//
// `run(cmd, args, {timeoutMs})` spawns a child, captures its stdout/stderr
// as strings, and resolves with `{code, stdout, stderr, timedOut, error?}`.
// Never throws. On spawn failure: `{code: -1, stderr: err.message, error}`.
// On timeout: SIGKILLs the child and resolves with `timedOut: true`.
//
// Intended for the "run a tool, inspect its exit code and output" pattern
// that shows up in operator-side checks (doctor.js) and pre-flight probes
// (probeConnectivity in runner.js). Long-lived PTY/ssh children that stream
// output to the user go through the `runHost` / `makeRemoteChild` path in
// `runner.js` instead — those have very different lifetime and signal
// requirements (detached process group, registry for SIGINT cleanup, etc.).

import {spawn} from 'node:child_process';

export function run(cmd, args, {timeoutMs} = {}) {
  return new Promise(resolve => {
    let stdout = '';
    let stderr = '';
    let timed = false;
    let proc;
    try {
      proc = spawn(cmd, args, {stdio: ['ignore', 'pipe', 'pipe']});
    } catch (err) {
      resolve({code: -1, stdout: '', stderr: err.message, error: err});
      return;
    }
    proc.stdout.on('data', c => (stdout += c));
    proc.stderr.on('data', c => (stderr += c));
    proc.on('error', err => resolve({code: -1, stdout, stderr: stderr || err.message, error: err}));
    let timer;
    if (timeoutMs) {
      timer = setTimeout(() => {
        timed = true;
        try { proc.kill('SIGKILL'); } catch {}
      }, timeoutMs);
    }
    proc.on('close', code => {
      if (timer) clearTimeout(timer);
      resolve({code: code ?? -1, stdout, stderr, timedOut: timed});
    });
  });
}
