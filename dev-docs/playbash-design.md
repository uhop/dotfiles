# Playbash — design notes

Technical rationale and protocol details for `playbash`, the multi-host bash playbook runner that replaced our ansible-based maintenance stack.

Companion docs:

- [`playbash-roadmap.md`](./playbash-roadmap.md) — milestone checklist and current status.
- [`playbash-debugging.md`](./done/playbash-debugging.md) — full debugging trail for the milestone-11 Mac PTY bugs.

## Why not pyinfra

[`pyinfra`](https://pyinfra.com/) was evaluated against current usage and ruled out:

- Operations abstraction (apt/apk/brew/zfs/...) is overkill — we only want to run existing shell commands.
- Step-synchronized fan-out across hosts; we want each host to run independently, in isolation.
- Playbooks are specialized Python modules and cannot be executed directly as scripts; we want plain shell files that remain runnable by hand for debugging.

## Shape

- **Runner**: Node CLI (`~/.local/bin/playbash`), single entrypoint, minimal deps. Handles inventory, connection lifecycle, sidecar collection, live output rendering, and the final summary.
- **Playbooks**: `bash` scripts at `~/.local/bin/playbash-*`, distributed via chezmoi to every managed host, sourcing `${PLAYBASH_LIBS:-$HOME/.local/libs}/playbash.sh` for the helper API. `PLAYBASH_LIBS` defaults to `~/.local/libs` and is overridable by the runner for upload mode (milestone 16). Playbooks stay readable, debuggable in isolation, and *directly runnable by hand* over plain `ssh` without setting any playbash-specific env vars — sidecar reporting activates only when `$PLAYBASH_REPORT` is set by the runner.
- **PTY wrapper**: `~/.local/libs/playbash-wrap.py`, a small Python script the runner spawns on the remote host to allocate a PTY for the playbook and propagate signals back to the bash subtree on disconnect. Replaces the original `script(1)` approach (see [PTY allocation](#pty-allocation) below).
- **Transport**: plain `ssh` / `rsync` / `sftp`. Connection multiplexing is delegated entirely to the user's existing `~/.ssh/config` (`ControlMaster auto`, `ControlPath ~/.ssh/sockets/%r@%h-%p`, `ControlPersist 5m`). See [Connection management](#connection-management) below.

## CLI surface

```
playbash run   <targets> <playbook> [-n LINES] [-p N] [--self]
playbash debug <targets> <playbook> [--self]
playbash exec  <targets> [--] <command...> [options]
playbash list
playbash hosts
playbash log   [path]
```

`<targets>` is one positional that may be a single host name, a comma-separated list, a group name, or the implicit `all` group — and any combination (`db1,web,prod`). Names are looked up in `~/.config/playbash/inventory.json`. Unknown names are passed verbatim to ssh, so any `~/.ssh/config` alias works. A single resolved target uses the live rectangle; multiple targets switch to a status board with parallel runs and a focused-host live view.

`<playbook>` resolves to `~/.local/bin/playbash-<playbook>` on the target host.

`debug` is equivalent to `run` with the rectangle disabled (`-n 0`) and `info` events surfaced in the summary — use it when you want to see everything.

`exec` runs an arbitrary command through the same wrapper / rectangle / fan-out pipeline as `run`, without a playbook script. The wrapper invokes `bash -c '<command>'` on the remote; locally, `bash -c` is spawned directly. No sidecar events are collected. Use `--` before the command when it contains flags that might conflict with playbash options. Same `-n`, `-p`, `--self` options as `run`.

`playbash log` prints a per-run log file with terminal-hostile escape sequences stripped — safe to view in any terminal. With no path, picks the most recent log under `~/.cache/playbash/runs/`. Direct `cat` of a log may inject control characters into the user's terminal.

## Inventory

Plain JSON, flat object, at `~/.config/playbash/inventory.json`. Chosen because Node parses it natively (no extra dep) and it's the same format as the sidecar — one parser to learn. Deployed identically to every managed host via chezmoi (`dot_config/playbash/inventory.json`).

### Schema

A value in the top-level object is one of:

- **String** — host address shorthand. `"web1": "web1.example.com"` is sugar for `{"address": "web1.example.com"}`.
- **Object with `address`** — host with extra attributes. Anything beyond `address` (`user`, `port`, ...) is currently informational; ssh-side overrides should live in `~/.ssh/config`.
- **Array of strings** — group. Members are flat host names; nested groups are rejected with a clear error.

```json
{
  "web1":      "web1.example.com",
  "db1":       { "address": "10.0.0.5", "user": "eugene", "port": 2222 },
  "mac":       "mac.local",
  "databases": ["db1"]
}
```

### Host argument resolution

The CLI takes one positional `<targets>` token, which may be comma-separated. Resolution:

- Tokens are split on `,` and trimmed.
- `all` expands to every host entry, alphabetically.
- A token matching a group name expands to its members in declaration order. Nested groups are rejected.
- A token matching a host entry expands to that one host (with the entry's `address` for ssh, the inventory name for display).
- An unknown token is passed verbatim to ssh, so `~/.ssh/config` aliases keep working unchanged. The inventory is purely additive.
- The result is deduped by name, preserving first-seen order.

The inventory is **optional**. If `~/.config/playbash/inventory.json` is missing, `run`/`debug` work as before and `hosts` prints a friendly "no inventory" message.

### Self host

The inventory is shared across hosts, so on each managed machine one entry refers to *that* machine. Running a playbook against self via ssh is wasteful (extra hop) and uses a slightly different code path (PTY behavior, environment, sudo whitelisting) than running it directly. The runner has to know which target is "me."

**Detection is runtime, by IP comparison. No config file, no chezmoi templating.**

At startup, the runner enumerates IPs bound to local interfaces via `os.networkInterfaces()` and adds the loopback ranges (`127.0.0.0/8`, `::1`). When about to ssh to a host, the runner does a `dns.lookup` on the address; if the resolved IP is in the local-IP set, the target is **self**. If DNS resolution fails (e.g. an `~/.ssh/config` `Host` alias that resolves only at ssh time), the target is treated as **remote** — a conservative miss the user can override with `--self`.

This treats "the same physical machine, however addressed" as one thing. On a host known as `think` (127.0.0.1) and `think.lan` (192.168.86.40), both names resolve to local IPs, so both are self. There is no scenario where you'd want a "remote" run to a LAN address that lands on the same `apt` lock and the same filesystem as a local run — they do the same thing, just with extra ssh plumbing.

**Default behavior:** running a playbook on self is **refused** with a clear error pointing at `--self` or the bare script (`playbash-upd`).

**`--self` flag:** opts in to running the playbook on the self host. Implementation runs the playbook **locally as a child process**, no ssh — same pipeline (Rectangle, sidecar, summary) as a remote run, with the sidecar at a local `mktemp` path. Same UX as a remote run; that's the whole point of using the runner on the self host.

`playbash hosts` marks self entries by resolving each entry's address against the local-IP set at command time (a few DNS lookups for a few hosts; cheap).

**Known blind spots, deferred fixes:**

- **VPN false positive.** If a VPN brings up an interface, addresses on it are detected as self. Fix when it bites: an optional `~/.config/playbash/not-self` allowlist of IPs to exclude from the local-IP set.
- **ssh-config alias false negative.** A `Host myalias` line in `~/.ssh/config` is invisible to `dns.lookup`. Fix when it bites: an optional `~/.config/playbash/self-aliases` allowlist of names that should always be considered self.

Both are speculative until real use surfaces them. The cost of adding a file later is one option name; the cost of building it speculatively is documenting and testing a feature nobody asked for.

### Groups and fan-out

- **Schema:** array values in `inventory.json`.
- **CLI:** comma-separated targets, mixing host and group names: `playbash run db1,web,prod upd`. Resolution flattens to a unique ordered set of host names.
- **Recursion:** groups are flat lists of *host* names. No groups-of-groups — keeps the mental model and dedup logic simple.
- **`all`:** implicit group, equals every host entry. Not stored; computed.
- **Self exclusion:** any list, however constructed (group, ad-hoc list, `all`), silently drops the self host by default with a one-line dim notice. `--self` flips this for the entire invocation. Explicitly naming self as a single argument still requires `--self`.
- **Parallelism:** unlimited by default; cap with `-p N`. A single resolved target uses the live rectangle; multiple targets switch to the `StatusBoard` with a sticky most-recently-active focused-host rectangle. Per-host summaries print in input order at the end, followed by a cross-host aggregated section. Continue-on-failure; the runner exits with code 1 if any host failed.

## Connection management

Playbash does not manage ssh control sockets at all. It just shells out to `ssh`, `rsync`, and `sftp`. The user's existing `~/.ssh/config` already enables multiplexing globally, so the first call opens a master under `~/.ssh/sockets/`, subsequent calls reuse it, and `ControlPersist` cleans up.

Consequences:

- Playbash's helpers stay trivial — no `-S`, no `-M`, no lifecycle code.
- Any interactive `ssh host` before or after a playbash run also benefits from the warm master. This is a feature.
- Playbash cannot forcibly close the master and must not try to (`ssh -O exit` would also kill unrelated sessions sharing the socket).
- A playbook longer than `ControlPersist` (5 min) is still fine — the master stays alive while connections are active; `ControlPersist` only counts idle time.
- **Cleanup on Ctrl+C does not propagate through the mux master.** Killing the local mux client only sends a channel-close to the master, which keeps the underlying TCP connection alive. sshd never observes a disconnect, never SIGHUPs the wrapper, and the wrapper's POLLHUP/EPIPE detectors never fire either. The runner works around this with the **PID preamble + remote-kill** mechanism described under [Cleanup on signal](#cleanup-on-signal) — the wrapper announces its PID over stdout before forking, the runner stores it per-host, and on signal cleanup the runner sends `ssh host kill -TERM <pid>` over a fresh channel that the master happily multiplexes alongside the stuck one.

Revisit if any of these become true: playbooks where deterministic teardown matters, or users without `ControlMaster auto` in their ssh config. The fallback is a private `/tmp/playbash.XXXX/` socket directory owned by playbash.

## Cleanup on signal

When the operator hits Ctrl+C (or `kill` sends SIGTERM/SIGHUP) to the runner, **every child process across every host must die**. There are three pieces:

1. **Local process registry.** Every spawn that owns its own process group (`detached: true`) registers itself in a `Set` at the top of `runner.js`. The runner installs SIGINT/SIGTERM/SIGHUP handlers on its own process. On signal: `process.kill(-child.pid, 'SIGTERM')` for each entry, which hits the entire process group (the spawn must be detached for the negative PID to mean "process group ID"). For `--self` runs, this is the whole story — the playbook's bash is in our group, gets the signal, dies.

2. **PTY wrapper signal trap.** For ssh-backed runs, the entry point on the remote side is `playbash-wrap.py`, a small Python wrapper that `pty.fork`s the playbook in the child and runs a poll loop in the parent. The wrapper installs `SIGTERM/SIGHUP/SIGINT/SIGPIPE` handlers that `os.killpg` the PTY child's process group, then exits. *This used to be the only remote cleanup path*, on the theory that killing the local ssh client would cause sshd to SIGHUP its child the way it does on a real connection drop.

3. **PID preamble + remote-kill.** That theory falls apart under ssh `ControlMaster` multiplexing. When the local mux client is killed, the master sends a `SSH_MSG_CHANNEL_CLOSE` to sshd but the underlying TCP connection stays alive (the master is still serving other channels and is held by `ControlPersist`). sshd does not synthesize a SIGHUP for what it sees as a clean channel close; the wrapper sees nothing. **Verified on the production fleet 2026-04-11**: a Ctrl+C'd `playbash run all daily` left the wrapper + bash + chezmoi + install-packages.sh + doas subtree alive on every Linux host, holding chezmoi state locks for 8+ minutes until manually killed.

   The fix is for the wrapper to *announce its own PID* to the runner over stdout before doing anything else:

   ```python
   # In playbash-wrap.py, BEFORE pty.fork:
   os.write(1, f"__playbash_wrap_pid {os.getpid()}\n".encode())
   ```

   The runner's `runHost` chunk handler buffers the head of the per-host stdout stream until either a newline arrives or 256 bytes pile up, then matches against `^__playbash_wrap_pid (\d+)$`. On match: the PID is stored in a `REMOTE_KILLABLE` map keyed by the local ssh child's PID; the matched line is stripped from the stream so it never appears in the rectangle, log, tail buffer, or stuck detector. On no-match (256 bytes without a recognizable preamble — i.e. a host running an older wrapper): the bytes are forwarded as-is and that host's run continues without a known remote PID. Backward-compatible.

   On signal cleanup, the runner does both:
   - `process.kill(-child.pid, 'SIGTERM')` for every local ssh client (existing behavior),
   - `spawn('ssh', [..., address, '--', 'kill -TERM PID; sleep 0.5; kill -KILL PID'])` for every remote wrapper PID it has on file. These are kicked off in parallel; the signal handler awaits up to 2 seconds for them to complete, then `process.exit(130)`. The fresh ssh channel for the kill *also* multiplexes over the stuck master — the master happily accepts new channels, it's just the existing ones that are stranded.

   `runHostSingle` and `runFanout` both check a `cleaningUp` flag before their normal `process.exit` calls, so a signal-handler cleanup in flight isn't truncated by the runner's own normal-exit path.

The combination — local registry + wrapper trap + remote-kill via PID preamble — gives deterministic teardown under every connection topology we run (mux, non-mux, --self, Linux target, macOS target). Verified end-to-end with `playbash exec all 'sleep 60'` + Ctrl+C → all hosts cleaned up within 2 seconds, exit code 130.

## Runtime model

Playbooks are expected to already live on the target host, distributed by `chezmoi` to the same conventional locations as everything else: scripts in `~/.local/bin/` and sourced helpers in `~/.local/libs/`. This is the **primary mode**. It mirrors how `upd`, `cln`, and `dcm` are deployed today, and it has two important properties:

- The playbook script is *directly runnable by hand* over plain `ssh` with no environment setup. Helpers are found via `${PLAYBASH_LIBS:-$HOME/.local/libs}/playbash.sh` (the default expands to the chezmoi-managed path). Sidecar reporting is opt-in: if `$PLAYBASH_REPORT` is unset, the helpers print human-readable output and skip the JSON-lines append.
- Playbash does not need to copy anything for the common case. It only sets a few env vars and runs the script.

A secondary **upload mode** for ad-hoc playbooks not yet in the chezmoi tree shipped in v3 (roadmap milestones 16 + custom playbook paths). See below.

### Primary mode

For each `(playbook, host)`:

1. **Resolve playbook path.** Look up `playbook` in the local registry → resolves to a path like `~/.local/bin/playbash-foo`. Playbash assumes the same path exists on the target (chezmoi guarantee).
2. **Run playbook.** The runner spawns `ssh "$host" -- env LC_ALL=C PLAYBASH_REPORT=... PLAYBASH_HOST=... COLUMNS=... LINES=... exec python3 -u ~/.local/libs/playbash-wrap.py ~/.local/bin/playbash-foo`. The Python wrapper allocates the PTY on the target and execvps the playbook in the child. The leading `exec` ensures python becomes the direct child of sshd's session shell with no intermediate `bash -c` to absorb signals.
3. **Capture output.** Runner reads ssh's stdout (which carries the PTY-multiplexed stream from the wrapper), keeps a rolling buffer of the last N lines (default 5), renders them as a fixed-height rectangle with ANSI cursor controls. The full uncut byte stream is also tee'd to `~/.cache/playbash/runs/<timestamp>-<host>-<playbook>.log` on the local side.
4. **Watch for stdin waits.** See [Interactive input detection](#interactive-input-detection) below.
5. **Collect sidecar.** When the playbook exits, fetch `$PLAYBASH_REPORT` via a follow-up `ssh "$host" -- cat $reportPath; rm -f $reportPath`. Parse it.
6. **Render summary.** Status line + grouped warnings / actions / errors.

The ssh master is left to `ControlPersist`.

A non-zero exit from the playbook is a hard failure. Warnings and suggested actions are *always* communicated through the sidecar, never through exit codes — this is the explicit lesson from the original ansible discussion.

### Directory playbooks

A custom playbook path (slash convention) may resolve to either a single file or a **directory**. Directory form is for ad-hoc playbooks that need to ship private helpers — the directory bundles the entry point and its sibling files into one self-contained artifact.

- **Trigger.** The slash-convention path resolves to a directory (`statSync(...).isDirectory()`). This is the only trigger; chezmoi-managed playbooks under `~/.local/bin/playbash-*` remain single-file (a directory there would lose the "runnable by hand over plain `ssh host playbash-foo`" property — directories aren't found by PATH lookup).
- **Entry point.** Hardcoded convention: `<dir>/main.sh`. Must exist and be a regular *executable* file. The runner validates both at the operator side before any ssh work; failures die fast with `chmod +x <path>` as the actionable hint. The exec bit is required (not silently chmod'd at upload time) so `cd <dir> && ./main.sh` works locally for debugging — same property the single-file convention guarantees, just applied to a dir.
- **Staging.** The entire tree is `tar c | ssh tar x`'d into `~/.cache/playbash-staging/<dirname>/` on the remote. The wrapper and helper library (`playbash-wrap.py`, `playbash.sh`) are staged as siblings at the staging root, shared with single-file pushes — `uploadStagedFiles` does a SHA-256 probe and only re-uploads changed files. The directory subdir itself is `rm -rf`'d before extraction so stale files from a previous push don't linger; `<dirname>` is validated against `[a-zA-Z0-9._-]+` and a small reserved-names set so the unquoted shell command line is injection-safe.
- **Helpers.** Sibling files in the directory are reachable from `main.sh` via `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)`. The wrapper exec's `main.sh` by absolute path, so `$0` is absolute and the standard idiom finds them. The playbash helper library is sourced via `$PLAYBASH_LIBS/playbash.sh` exactly as in the single-file case — `PLAYBASH_LIBS` points at the staging root, where the staged `playbash.sh` lives.
- **Templated paths.** A path like `./reports/{host}/` is allowed and resolves per host. Validation is deferred to per-host expansion — for fan-out runs, a malformed dir on one host becomes a per-host failure (caught and reported in the status board) and does not abort in-flight runs on other hosts.
- **Caveat.** Like single-file `push`, only self-contained playbooks work — a directory playbook that depends on chezmoi-managed scripts (`upd`, `cln`, `dcms`) is no different from a single-file playbook with the same dependency.

The runner code is unified: `runRemote` and `runFanout` each call `validateCustomPlaybookPath` once and dispatch to `stagePlaybookDir` or `stagePlaybookFiles` based on the result. `buildRemoteCommand` is shape-agnostic — it just receives the absolute remote path of the entry point.

### Interactive input detection

Some commands (notably `chezmoi update` when it needs to install system packages) sporadically drop into a `sudo` password prompt. More generally, *any* prompt for stdin is a problem under playbash: the playbook has no tty for the user and would just hang.

The detection is regex-based, on a sliding window of recent output, plus an idle-output watchdog as a backstop:

- **Regex match.** A sliding 4 KB window of the captured output is checked for known prompt patterns (`[sudo] password for`, `Password:` at end of line, `doas (...) password:`, `Sorry, try again`, `sudo: a terminal is required`, ...). Strong signal, fires immediately, very low false-positive risk because the patterns are specific. `LC_ALL=C` is forced on the remote side so prompts are predictable.
- **Idle-output watchdog.** No chunks received for N seconds while the child is still alive. Default 90s — generous enough that apt downloads and brew from-source compiles don't trip it. `PLAYBASH_STDIN_WATCH_TIMEOUT=0` disables; any positive integer overrides the default.

On detection: SIGTERM the entire process group, then SIGKILL after a 5-second grace period. The host's status word becomes either `needs sudo` (regex matched) or `stuck (idle)` (threshold tripped). In the summary the host shows as a failure (✗), but with the distinct status word so the user can tell it apart from a real non-zero exit. Surfaced per-host so a daily run across many hosts produces a clean "these N hosts need you" list rather than a wall of stderr.

The original v2 plan called for a Linux-only precise path inspecting `/proc/$pid/wchan` to flag descendants blocked in `tty_read` / `n_tty_read`. It was deferred during dogfooding — the cheap regex path turned out to catch every prompt we hit in practice, and the precise path's added complexity wasn't justified.

#### The Mac PTY bugs (resolved during milestone 11)

Two subtle bugs in `playbash-wrap.py` had to be fixed before the kill path actually propagated end-to-end against Mac targets. The wrapper itself is platform-agnostic, but Mac/Darwin behaves differently from Linux in two ways that matter here. Full debugging trail in [playbash-debugging.md](./done/playbash-debugging.md).

1. **`select.poll()` on Darwin doesn't deliver `POLLHUP` on a closed pipe write end.** When the local ssh died (because the operator-side runner killed it after a regex match), the wrapper on the Mac target sat in `os.read(pty_master)` indefinitely if the playbook was silent — no notification that sshd had closed its stdout. Fixed by a 1-second `os.write(1, b"")` probe: a zero-byte write raises `EPIPE` reliably on Darwin within milliseconds of the read end closing, on every wake of `poll()`. Costs one syscall per second of idle time.

2. **macOS `waitpid` deadlock at exit.** When the `pty.fork()` child is a session leader and its subtree includes a program that grabbed the controlling terminal in raw mode (e.g. `sudo` reading a password), the kernel cannot finish revoking the controlling terminal — and therefore cannot finish the child's exit — while another process still holds the PTY master fd open. The child stalls in `?Es` state and `waitpid` blocks forever, holding sshd's pipes half-closed and leaking the entire ssh channel. Fixed by `os.close(fd)` on the PTY master immediately before `waitpid`. Linux is unaffected either way (the master can stay open).

The original test payload used `read -p` for the prompt, which masked bug 2 — `read` doesn't manipulate termios. Only programs that put the PTY into raw mode trigger the kernel revoke stall. **Lesson:** never use `read -p` as a stand-in for `sudo` in PTY tests. Use a real `sudo` invocation (or a tiny C/Python program that calls `tcsetattr` to put the tty into `cbreak` mode).

## Sidecar protocol

The sidecar is a single file on the remote host whose path is in `$PLAYBASH_REPORT`. The playbook (via helpers) appends one JSON object per line. JSON-lines is chosen for: append-safety, partial-read tolerance, and trivial parsing.

### Event schema

Required fields:

| field   | type   | meaning |
|---------|--------|---------|
| `ts`    | string | ISO-8601 timestamp, set by helper |
| `level` | string | one of: `info`, `warn`, `action`, `error` |
| `msg`   | string | human-readable message |

Optional fields:

| field    | type   | meaning |
|----------|--------|---------|
| `kind`   | string | required for `action`; e.g. `reboot`, `restart-service`, `manual-step` |
| `target` | string | what the event is about (service name, file path, package, ...) |
| `data`   | object | free-form structured payload (e.g. `{"packages": 12}`) |
| `step`   | string | playbook-defined step label, for grouping in the summary |

### Levels

- `info` — progress note worth keeping in the summary (e.g. "installed 12 packages"). Not surfaced unless `--verbose` (or `debug`).
- `warn` — something the user should know but no action needed.
- `action` — something the user *should do* after the run; `kind` is required and machine-readable so the runner can aggregate ("3 hosts need reboot").
- `error` — non-fatal error the playbook chose to record and continue past. Fatal errors are conveyed by exit code + captured stderr, not the sidecar.

### Helper APIs

Two helpers write to the sidecar, depending on which library a script sources:

**`~/.local/libs/playbash.sh`** — original API for purpose-built playbooks:

```bash
playbash_info  "installed 12 packages"
playbash_warn  "disk usage above 80%" --target /var
playbash_action reboot "kernel updated to 6.17.2"
playbash_error "could not restart nginx, continuing"
playbash_step  "package-upgrade"          # sets $PLAYBASH_STEP for subsequent events
playbash_data  '{"packages": 12}'         # attached to the next event
```

**`~/.local/libs/maintenance.sh`** — used by `upd` and `cln` so they remain runnable by hand outside playbash:

```bash
report_reboot "kernel updated to 6.17.2"
report_warn   "disk usage above 80%" --target /var
report_action restart-service "nginx config changed" --target nginx
```

Each `report_*` helper does two things: prints the colored, human-readable message via `options.bash` (the historical behavior), AND appends a JSON-lines event to `$PLAYBASH_REPORT` when set. The maintenance helper has its own inlined JSON writer; it does **not** depend on `playbash.sh`. Maintenance scripts and the playbash runner are conceptually separate; we don't want a transitive dependency from `upd`/`cln` onto the playbash helper library.

Helpers must never fail the playbook — they swallow their own errors and write to `stderr` if the report file is unwritable. Each helper writes one line with a `flock` for safety.

### Aggregation in the summary

The runner groups events by `level` and, for actions, by `kind`. Per-host renderer dedupe and per-host aggregator dedupe collapse identical events from multiple sources (e.g. `upd` + `cln` both reporting the same docker reboot) into one user-visible line. Example output:

```
host web1.example.com: ok (12.3s)
  ⏵ reboot — kernel updated to 6.17.2
  ⚠ /var: disk usage above 80%
```

Across multiple hosts, the same aggregation runs at the cross-host level: "2 hosts need reboot: web1, db1".

## Live output rendering

- Playbook output is read off ssh's stdout, where it arrives PTY-multiplexed (allocated on the target by `playbash-wrap.py`, see [PTY allocation](#pty-allocation)).
- The runner maintains a ring buffer of the last N lines (default 5, configurable via `-n`, set `-n 0` to disable the rectangle and stream sanitized output raw).
- Re-renders the rectangle in place using ANSI cursor save/restore + clear-to-end-of-line. Wraps/truncates long lines to terminal width.
- Treats `\r\n` as a single line ending; only treats lone `\r` as a progress-bar line reset. PTY-translated streams use `\r\n`, so getting this wrong wipes every line before commit (this was a bug caught during milestone-5 dogfooding).
- Strips terminal-hostile escape sequences (cursor positioning, OSC, DCS, CPR queries, alt-screen, ...) from the byte stream **before** display, in *both* rectangle and raw modes. Keeps SGR (color) escapes. The full uncut stream still goes to the log file.
- On exit, clears the rectangle and prints the final status line.
- Always also writes the full uncut stream to `~/.cache/playbash/runs/<timestamp>-<host>-<playbook>.log`. Use `playbash log [path]` to view a log safely (sanitized) — direct `cat` of a log file may inject control characters into the user's terminal.

The summary uses minimal color: green ✓, bold-white-on-red ✗ block, magenta ⏵ for actions, orange ⚠ for warnings. Orange (instead of yellow) was chosen for dark/light terminal compatibility. `NO_COLOR` and `PLAYBASH_NO_COLOR` env overrides are honored.

See [`tty-simulation.md`](./done/tty-simulation.md) for additional background on the `script(1)`/`tee` pattern.

### PTY allocation

The PTY is allocated **on the target** by `~/.local/libs/playbash-wrap.py`, a small Python script. ssh runs with plain pipes on both sides (no `-tt`).

Why a wrapper at all:

- **No OSC-query echo-back.** Earlier (milestone 5) we used `script -qfec '<cmd>' /dev/null` (util-linux). Earlier still we used `ssh -tt`. With `ssh -tt`, terminal queries from remote tools (OSC 11 background-color, CPR `\x1b[6n`, etc.) flowed back through ssh into the **local** terminal, which generated responses, which were written to Node's stdin, which we never read, which sat in the terminal's input buffer until Node exited — at which point the user's shell read them as typed input (visible as ANSI gibberish at the prompt). Allocating the PTY remotely fixes this: queries are answered (or simply not asked) by the remote PTY and never reach the local terminal.
- **Cross-platform.** util-linux `script(1)` is Linux-only; BSD `script(1)` on macOS has different argument syntax and different buffering behavior. A Python wrapper works identically on both — Python ships everywhere we care about, and `pty.fork()` plus `select.poll()` are stdlib.
- **Robust subtree cleanup.** The wrapper installs `SIGTERM`/`SIGHUP`/`SIGINT`/`SIGPIPE` handlers that `killpg` the child's process group, plus a 1-second probe of `os.write(1, b"")` to detect parent-pipe-close even when the playbook is silent. Both are necessary because of the Mac quirks documented in [Interactive input detection § Mac PTY bugs](#the-mac-pty-bugs-resolved-during-milestone-11).

The wrapper is ~120 lines, deployed via chezmoi to every managed host alongside `playbash.sh`. The runner builds the remote command line as plain string interpolation — host names are validated against `[a-zA-Z0-9._-]`, playbook names against the same regex — so injection is not a concern.

## Repository layout

```
private_dot_local/
  bin/
    executable_playbash                 # Node CLI entrypoint (local-only)
    executable_playbash-hello           # sample playbook
    executable_playbash-sample          # sample playbook
    executable_playbash-daily.tmpl      # daily orchestration playbook
    executable_playbash-weekly.tmpl     # weekly orchestration playbook
  libs/
    playbash.sh                         # general-purpose helper API (deployed everywhere)
    playbash-wrap.py                    # Python PTY wrapper (deployed everywhere)
    maintenance.sh                      # report_* helpers used by upd/cln (deployed everywhere)
  private_share/
    playbash/
      render.js                         # Rectangle, HostSlot, StatusBoard, COLOR, sanitizer
      inventory.js                      # load, resolve, self detection, target filtering
      sidecar.js                        # JSON-lines parser, per-host + cross-host aggregation
      staging.js                        # wrapper staging for vanilla hosts, BatchMode ssh
      doctor.js                         # `playbash doctor` env + per-host diagnostic
      ssh-config.js                     # parseHostNames(): walk ~/.ssh/config + Includes
      completion.bash                   # bash completion script (read by --bash-completion)
    utils/
      comp.js                           # general-purpose comparison helpers
      semver.js                         # semver parsing
      nvm.js                            # nvm interop
```

Notes:

- Playbooks, `playbash.sh`, `playbash-wrap.py`, and `maintenance.sh` are deployed to *every* managed host via chezmoi. The runner sources under `private_share/playbash/` are local-only — they live on the operator's machine and are imported by `executable_playbash` via relative paths like `../share/playbash/render.js`.
- General-purpose helpers (`comp.js`, `semver.js`, `nvm.js`) live in `private_share/utils/` and are imported by other Node executables (`update-node-versions.js`, `trim-node-versions.js`).
- There is no `connection.js` because connection lifecycle is delegated to `~/.ssh/config` (see [Connection management](#connection-management)).
- `cmdList` filters out `.js` files defensively, in case future helpers land in `bin/`.
- Dependency graph: entry → all four playbash modules; sidecar → render (for `COLOR`). No cycles.
- All ssh invocations pass `-o BatchMode=yes`. Passwordless auth (key agent or pre-configured public-key) is a hard requirement — same as ansible / pyinfra / fabric. Auth failures are fast and deterministic.

## Reboot/warning reporting in upd/cln

`upd` and `cln` historically formatted their reboot recommendations and warnings using `options.bash`. The milestone-9 refactor factored that print logic into the `report_*` helpers in `maintenance.sh`, with two guarantees:

- Always prints the formatted message locally (preserves the manual-run behavior).
- *Additionally*, when `$PLAYBASH_REPORT` is set, appends a structured event to the sidecar.

This keeps the scripts runnable by hand exactly as before and gives the runner machine-readable events for free.

### apt history scanning

Both `upd` and `cln` snapshot the byte position of `/var/log/apt/history.log` before doing apt operations and call `maintenance::check_apt_since` afterwards. The function diffs the new tail of `history.log`, scans the `Upgrade:` lines for known package names, and reacts:

- **Docker-related upgrade** (`docker-ce`, `containerd`, `docker-buildx-plugin`, `docker-compose-plugin`) → if `upd --restart-services` was passed, `maintenance::restart_docker_services` runs `sudo systemctl restart containerd && sudo systemctl restart docker` (both whitelisted in the doas config). On failure, falls back to `report_reboot`. Otherwise, `report_reboot "docker upgraded; restart recommended"`.
- **AppArmor upgrade** → marks `~/.cache/playbash/needs-aa-cleanup` and immediately runs `aa-remove-unknown` to keep docker working. The marker persists across runs so an interrupted cleanup completes on the next `upd`/`cln` invocation (recovery path).
- **`/run/reboot-required` exists** (any cause, kernel etc.) → `report_reboot` with the package list from `.pkgs` as the reason if available.

Linux-only. The functions are no-ops on Mac (no apt, no `/var/log/apt`).

### Background: the docker-ce silent break

Caught during milestone-5 dogfooding, confirmed twice. When `apt` upgrades `docker-ce`, the docker daemon stops working properly (`docker compose up` fails with container conflicts) but no `/run/reboot-required` is created. The user has to know to reboot. The first occurrence on `croc` was diagnosed by manually rebooting and re-running `dcm`; a second occurrence was caught by the same pattern. The pre-emptive `dpkg.log` scan in `maintenance::check_apt_since` (above) detects this automatically — and milestone 12's `--restart-services` flag offers an automatic recovery without a full reboot.

## Doctor

`playbash doctor` is a one-shot diagnostic that surfaces operator-environment problems and per-host connectivity issues with remediation hints, before the user hits a cryptic ssh error mid-playbook. Lives in `private_share/playbash/doctor.js`; the runner imports `runDoctor()` and dispatches via a single `case` branch.

Two sections:

- **Environment** (sequential, operator-side). Each item produces a `{name, status, message, hint?}` record with `status` ∈ `{ok, warn, fail}`:
  - `~/.ssh/config` exists.
  - Effective `ControlMaster`, `ControlPersist`, `ControlPath` queried via `ssh -G nonexistent.example.invalid` — using a non-routable hostname makes the call fast (no network) while still letting `Host *` and `Match` blocks apply. The output is parsed into a `Map<lowercased option name, value>`. `ControlMaster auto` is `ok`; anything else (or unset) is `warn` with a hint.
  - At least one of `id_ed25519`, `id_rsa`, `id_ecdsa`, `id_dsa` exists in `~/.ssh`.
  - `ssh-add -L` exit 0 with output → `ok` (count of identities). Exit 1 (no identities) or 2 (no agent) → `warn` (best-effort: macOS keychain may bypass the agent).
  - Inventory file present + parseable via the existing `loadInventory()`. Missing inventory is `warn` (it's optional).
  - `~/.local/bin/playbash-*` are present and executable. Non-executable entries → `fail` with a `chmod +x` hint.
  - `~/.local/libs/playbash.sh` and `~/.local/libs/playbash-wrap.py` exist locally — operator side, needed for `--self` runs and for staging to non-managed hosts.
  - `python3 --version` succeeds on PATH.

- **Hosts** (parallel, per inventory entry). Each host accumulates a list of items; the host's overall status is the worst of any item:
  - **Self skip.** `isSelfAddress` from `inventory.js`; self entries record a single `(self) — skipped` `ok` item and bypass the ssh probe.
  - **ssh-config alias presence.** Walk `~/.ssh/config` plus `Include` directives (relative paths resolved against `~/.ssh`, the common `dir/*` glob handled inline without a glob lib), collect literal `Host` patterns (skipping wildcards `*`/`?`). The check only fires when the inventory address looks like a *short* name (no `.` or `:`) — FQDNs and IPs resolve directly via DNS and don't benefit from a Host alias. A short name with no matching Host entry is a `warn` with a hint to add one so user/port/identity become explicit.
  - **Connectivity probe.** `ssh -o BatchMode=yes -o ConnectTimeout=5 <addr> true` with an 8-second outer timeout that SIGKILLs the subprocess (the `run()` helper in doctor.js handles this generically — never throws, always resolves with `{code, stdout, stderr, timedOut}`). Failures are routed through `classifySshError()` which buckets stderr into `auth`, `timeout`, `refused`, `no route`, `unknown host`, `host key`, `connection drop`, or a 60-char fallback, each with a tailored hint.

The renderer aligns the env section with two padded columns (`name` and `message`) and the host section with three (`name`, `address`, item label), reusing `COLOR` from `render.js` for the `✓ / ⚠ / ✗` glyphs and dim hint arrows. Single-item hosts inline; multi-item hosts stack their items under the host row. The summary line `N ok · N warn · N fail` is computed across the union of env and host items. Exit code is 1 if any `fail` is present (warns are non-fatal), 0 otherwise.

The whole module is one-shot: no shared state with the runner, no caching, no opt-in flags. ~310 lines, no third-party deps. Adding new checks is a matter of pushing one more `result(...)` into `checks` (env) or `out.items` (host).

## Versioning

`playbash --version` (short: `-v`) prints `playbash <semver>` and exits 0. The version lives as a single `VERSION` constant near the top of `bin/executable_playbash`, just above `USAGE`. One place to bump, one place to grep for.

**Scheme:** loose semver — `MAJOR.MINOR.PATCH`.

- **MAJOR** tracks the roadmap's `vN` milestones in [`playbash-roadmap.md`](./playbash-roadmap.md). `1.x.x` = v1 (proof of concept), `2.x.x` = v2 (production polish), `3.x.x` = v3 (portability to vanilla hosts). A major bump means a meaningfully different product (new transport model, new deployment story, etc.) and gets its own roadmap section.
- **MINOR** bumps on any user-visible feature addition or behavior change: a new subcommand, a new flag, a new sidecar event kind, a change in exit-code semantics, a change in default output that scripts might be parsing. v3 follow-ups (milestones 18–24) are minor bumps within `3.x.x`.
- **PATCH** bumps on bug fixes and pure internal refactors with zero user-visible behavior change.

**Bump policy:** every commit that changes playbash's behavior, CLI surface, or output should update `VERSION` in the same commit. Refactors that don't touch behavior (file splits, `die()` consolidation, etc.) also get a patch bump so `--version` reflects the actually-running code and bisection has a usable anchor. The version is the single source of truth for "what's installed" — the wiki and release notes trail it, not the other way around.

**Current:** `3.0.0` — snapshot at the end of the v3 roadmap close. Subsequent v3 follow-ups (cleanup-on-signal, ssh-config completion enrichment, doctor, directory playbooks, `die()` consolidation, `--version` itself) will start bumping from this baseline.

**Not tracked in `--version`:** the staging cache format, the sidecar protocol version, the PTY wrapper's own version. Those are separate concerns with their own evolution — the sidecar is a newline-delimited JSON stream where consumers ignore unknown event fields; the wrapper announces its protocol via the `__playbash_wrap_pid` preamble (absence = older wrapper, runner falls back gracefully). Bundling all of that into the CLI version would conflate independent compat stories.
