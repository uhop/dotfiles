# Playbash debugging

The problem: we cannot detect a password prompt when running remotely against a Mac
target. It works locally on Mac, it works in both directions on Linux, but it fails
when the operator is Linux and the target is Mac.

We already switched from `script` to a Python wrapper, and the problem persists. The
whole debacle likely stems from systemic issues with the approach.

Questions:

- Is there really a difference between local and remote execution? `runLocally()` and
  `runRemote()` are separate code paths — how do we know the divergence isn't hiding
  the bug?
- An AI agent claimed BSD `script` differs from Linux `script` in that the former
  buffers output, so it never reaches our regex matcher. Do we have a clean repro?
- We debug via the `upd` utility, which may ask for a sudo password. Linux uses `doas`
  (configured passwordless for `upd`); Mac uses `sudo`, which always prompts. Would
  switching Linux to `sudo` reproduce the same problem?

## Minimal runner

Instead of debugging the full `playbash` utility, distill the problem into a
**minimally reproducible case**. Drop the local-vs-remote split for now — run
everything remotely via `ssh`, including ssh-ing into the same machine. That lets us
log every aspect of the runner to a local file for later inspection.

## Minimal payload

The script we run should be as small as possible. Start with:

```bash
echo Start
read -p "Pattern:" answer
echo "Finish. Answer: $answer"
```

No `sudo` involved — we just try to match `Pattern:` (or any other text). If that
works, escalate to a script that triggers a real password prompt while avoiding
`doas`:

```bash
echo Start
command sudo ls
echo Finish
```

Use this as the debugging target.

## Local runner

We already have a Python wrapper (`playbash-wrap.py`) that is streamed from a local
file into a remote `python3` over `ssh`.

First confirm the wrapper runs correctly **without** `ssh`. Then run it **with**
`ssh`. If only the latter fails, the `ssh` bridge is the problem and we tackle it
separately.

The wrapper is already small, but if it gets in the way, shrink it further to the
minimum needed to reproduce the bug.

## Tracing / logging

Stop relying on subtle side effects and guesswork. Trace every action and event to a
local file (we are running locally, even over `ssh`). With a minimal repro, adding
logs is cheap.

Stream-event problem? Log every stream event. And so on.

## Clean up

Each failed fix left dead code behind, and the next attempt piled more on top of it.
Avoid that trap: work from minimal code each iteration, and once the bug is fixed,
thoroughly prune all `playbash`-related code back to the smallest working form.

# Summary

Start as small as possible: a stand-in for `playbash`, a tiny script to run, and a
harness that runs the script on a remote end.

Use the current machine as the `ssh` target — it makes debugging much easier.

Use logging/tracing to understand the actual flow.

Once we know how to handle it, scale back up to the real `playbash` codebase.

# Resolution (2026-04-08)

The minimal harness reproduced the hang on a single Mac via `ssh localhost`,
which let us isolate two distinct Mac-only failure modes:

1. **POLLHUP silence on macOS** — Python's `select.poll()` on Darwin does not
   deliver `POLLHUP` on a closed pipe write end. The wrapper's
   `os.write(1, b"")` 1-second probe (already in place from the previous
   round) handles this correctly: the probe raises `EPIPE` when sshd has
   half-closed the wrapper's stdout, and the loop exits. The `read -p` test
   payload confirmed this path works end-to-end.

2. **`waitpid` deadlock at exit** — when the `pty.fork()` child is a session
   leader and its subtree includes a program that grabs the controlling
   terminal (e.g. `sudo` reading a password), the kernel cannot finish
   revoking the controlling terminal — and therefore cannot finish the
   child's exit — while another process still holds the PTY master fd
   open. The child stalls in `?Es` state and `os.waitpid(pid, 0)` blocks
   forever, leaking the entire ssh channel. **The `read -p` payload
   masked this bug**: only programs that put the PTY into raw mode trigger
   the kernel revoke stall.

   **Fix:** close the PTY master fd immediately before `waitpid` in
   `private_dot_local/libs/playbash-wrap.py`. One-line change. Linux is
   unaffected (master can stay open without blocking child exit).

   Verified on this Mac via the harness in `~/pbdebug/`:
   `read -p` payload: 2.6s, sudo payload (pre-fix): 10s deadline,
   sudo payload (post-fix): 2.04s. No orphans.

Lesson for future debugging: **never use `read -p` as a stand-in for
`sudo`.** The PTY surface looks the same but the kernel teardown path
isn't.

## Open / TODO

- **Defensive `waitpid` with timeout + `SIGKILL` escalation.** The
  close-fd fix is the proven primary cleanup. As belt-and-braces against
  future Mac kernel quirks, the final `os.waitpid(pid, 0)` could be
  wrapped in a small loop using `WNOHANG` with a short deadline that
  escalates to `SIGKILL` if reaping doesn't happen. Deliberately deferred
  to avoid unnecessary complexity in code that should stay minimal —
  revisit only if a similar deadlock surfaces again.

- **End-to-end test against the real `playbash` runner.** The minimal
  harness proves the wrapper itself is correct on Mac. The real
  `playbash run mini2 daily` from the Linux operator is still pending
  validation. To smoke-test locally (Mac-only) without touching Linux,
  temporarily comment out the `runLocally()` / `runRemote()` branch in
  `dispatchRun()` so all runs go through `runRemote()`, then run
  `playbash run localhost fakesudo` against this machine.

- **Cleanup of `playbash`-related code per the "Clean up" section above.**
  Once Linux end-to-end is validated, prune any remaining failed-attempt
  artifacts and update `dev-docs/playbash-roadmap.md` milestone 10
  with the final root cause.
