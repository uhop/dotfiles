#!/usr/bin/env python3
# playbash-wrap.py — PTY wrapper used by the playbash runner to launch a
# playbook on a remote host with a real controlling terminal AND robust
# cleanup of the bash subtree on parent disconnect.
#
# Usage: python3 -u playbash-wrap.py <playbook-path> [args...]
#
# The wrapper:
#   1. pty.forks and execvps the playbook in the child (gets its own
#      session/process group via setsid, so killpg reaches the entire
#      subtree — bash, sudo, apt, anything it spawns).
#   2. In the parent, polls the PTY master in one select.poll call with
#      a 1-second tick. On every wake, probes fd 1 with a zero-byte write
#      to detect parent-pipe-close. This is the load-bearing piece: when
#      sshd closes the wrapper's stdout (because the local ssh client
#      died, the operator-side runner killed it, the network dropped,
#      …) the next zero-byte write raises EPIPE — *even when the playbook
#      is silent*, on every platform we run.
#
#      On Linux we could use `poll()` with `POLLHUP` on fd 1 for
#      sub-millisecond latency. We don't, because Python's `select.poll`
#      on macOS is emulated over `select(2)` and does NOT deliver POLLHUP
#      on a closed pipe write end. The macOS-only path would hang
#      forever in `os.read(pty_master)` if the playbook is silent —
#      observed in milestone-11 dogfooding when the operator's stdin-watch
#      detected a sudo prompt and killed the local ssh, but the wrapper
#      on the Mac target sat in poll() and never noticed sshd had closed
#      its stdout. The zero-byte-write probe is uniform across Linux and
#      Darwin and costs one syscall per second of idle time.
#   3. Installs SIGTERM/SIGHUP/SIGINT/SIGPIPE handlers that killpg the
#      bash group, as a belt-and-braces second cleanup path.
#
# Deployed via chezmoi to ~/.local/libs/playbash-wrap.py on every managed
# host. The runner invokes it via:
#
#   ssh host -- 'LC_ALL=C PLAYBASH_REPORT=... PLAYBASH_HOST=... \
#                COLUMNS=... LINES=... \
#                exec python3 -u ~/.local/libs/playbash-wrap.py \
#                              ~/.local/bin/playbash-<name>'
#
# `exec` so python becomes the direct child of sshd's session shell with
# no intermediate bash -c layer that could otherwise absorb a signal.

import os, pty, select, signal, sys

if len(sys.argv) < 2:
    sys.stderr.write("usage: playbash-wrap.py <playbook> [args...]\n")
    sys.exit(2)

pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])

done = False
def _kill(*_):
    global done
    done = True
    try:
        os.killpg(pid, signal.SIGTERM)
    except Exception:
        pass

for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGPIPE):
    signal.signal(s, _kill)

p = select.poll()
p.register(fd, select.POLLIN | select.POLLHUP | select.POLLERR)

try:
    while not done:
        try:
            events = p.poll(1000)
        except InterruptedError:
            continue
        # Probe fd 1 every wake (poll timeout or PTY readable). A
        # zero-byte write raises EPIPE if the read end is closed but is
        # a no-op otherwise — gives us reliable parent-disconnect
        # detection on macOS where poll() doesn't deliver POLLHUP.
        try:
            os.write(1, b"")
        except (BrokenPipeError, OSError):
            _kill()
            break
        for efd, ev in events:
            if efd == fd:
                if ev & select.POLLIN:
                    try:
                        d = os.read(fd, 4096)
                    except OSError:
                        done = True
                        break
                    if not d:
                        done = True
                        break
                    try:
                        os.write(1, d)
                    except (BrokenPipeError, OSError):
                        _kill()
                        break
                elif ev & (select.POLLHUP | select.POLLERR):
                    done = True
                    break
finally:
    try:
        os.killpg(pid, signal.SIGTERM)
    except Exception:
        pass

# Close the PTY master BEFORE waitpid. On macOS, when the pty.fork() child
# is a session leader and its subtree includes a program that grabbed the
# controlling terminal in raw mode (e.g. `sudo` reading a password), the
# kernel cannot finish revoking the controlling terminal — and therefore
# cannot finish the child's exit — while another process still holds the
# PTY master fd open. The child stalls in `?Es` state and waitpid below
# blocks forever, holding sshd's stdin/stdout pipes half-closed and
# leaking the entire ssh channel. Closing the master here lets the
# revoke complete so the child can transition to a zombie and waitpid
# can reap it. Linux is unaffected either way (master can stay open).
# See dev-docs/playbash-debugging.md for the minimal repro.
try:
    os.close(fd)
except OSError:
    pass

_, st = os.waitpid(pid, 0)
# Portable exit-code extraction — works back to Python 3.3 (no
# os.waitstatus_to_exitcode which requires 3.9+).
if os.WIFEXITED(st):
    raise SystemExit(os.WEXITSTATUS(st))
elif os.WIFSIGNALED(st):
    raise SystemExit(128 + os.WTERMSIG(st))
else:
    raise SystemExit(1)
