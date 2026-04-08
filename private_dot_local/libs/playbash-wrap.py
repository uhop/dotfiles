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
#   2. In the parent, polls the PTY master AND fd 1 in one select.poll
#      call. The fd 1 watch is the load-bearing piece: when sshd closes
#      the wrapper's stdout (because the local ssh client died, the
#      operator-side runner killed it, the network dropped, …), POLLHUP
#      fires on the write end immediately — *even when the playbook is
#      silent*. Without this, a playbook blocked in `sleep`, `apt update`,
#      or an unanswered `sudo` prompt would hang the wrapper forever in
#      a blocking read on the PTY master, leaking the bash subtree as
#      orphans on the remote host. (Symptom: "still hangs remotely from
#      a Linux host" during milestone-11 dogfooding.)
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
p.register(fd, select.POLLIN)
p.register(1,  select.POLLHUP | select.POLLERR)

try:
    while not done:
        try:
            events = p.poll(1000)
        except InterruptedError:
            continue
        for efd, ev in events:
            if efd == 1 and (ev & (select.POLLHUP | select.POLLERR)):
                _kill()
                break
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

_, st = os.waitpid(pid, 0)
raise SystemExit(os.waitstatus_to_exitcode(st))
