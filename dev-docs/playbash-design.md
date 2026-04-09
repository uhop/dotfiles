# Playbash — design notes

Technical rationale and protocol details for `playbash`, the multi-host bash playbook runner that replaced our ansible-based maintenance stack.

Companion docs:

- [`playbash-roadmap.md`](./playbash-roadmap.md) — milestone checklist and current status.
- [`playbash-debugging.md`](./playbash-debugging.md) — full debugging trail for the milestone-11 Mac PTY bugs.

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
playbash run   <playbook> <targets> [-n LINES] [-p N] [--self]
playbash debug <playbook> <targets> [--self]
playbash list
playbash hosts
playbash log   [path]
```

`<targets>` is one positional that may be a single host name, a comma-separated list, a group name, or the implicit `all` group — and any combination (`db1,web,prod`). Names are looked up in `~/.config/playbash/inventory.json`. Unknown names are passed verbatim to ssh, so any `~/.ssh/config` alias works. A single resolved target uses the live rectangle; multiple targets switch to a status board with parallel runs and a focused-host live view.

`<playbook>` resolves to `~/.local/bin/playbash-<playbook>` on the target host.

`debug` is equivalent to `run` with the rectangle disabled (`-n 0`) and `info` events surfaced in the summary — use it when you want to see everything.

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
- **CLI:** comma-separated targets, mixing host and group names: `playbash run upd db1,web,prod`. Resolution flattens to a unique ordered set of host names.
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

Revisit if any of these become true: playbooks where deterministic teardown matters, or users without `ControlMaster auto` in their ssh config. The fallback is a private `/tmp/playbash.XXXX/` socket directory owned by playbash.

## Runtime model

Playbooks are expected to already live on the target host, distributed by `chezmoi` to the same conventional locations as everything else: scripts in `~/.local/bin/` and sourced helpers in `~/.local/libs/`. This is the **primary mode**. It mirrors how `upd`, `cln`, and `dcm` are deployed today, and it has two important properties:

- The playbook script is *directly runnable by hand* over plain `ssh` with no environment setup. Helpers are found via `${PLAYBASH_LIBS:-$HOME/.local/libs}/playbash.sh` (the default expands to the chezmoi-managed path). Sidecar reporting is opt-in: if `$PLAYBASH_REPORT` is unset, the helpers print human-readable output and skip the JSON-lines append.
- Playbash does not need to copy anything for the common case. It only sets a few env vars and runs the script.

A secondary **upload mode** for ad-hoc playbooks not yet in the chezmoi tree is planned for v3 (see roadmap milestone 16). v1/v2 only ship the primary mode.

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

### Interactive input detection

Some commands (notably `chezmoi update` when it needs to install system packages) sporadically drop into a `sudo` password prompt. More generally, *any* prompt for stdin is a problem under playbash: the playbook has no tty for the user and would just hang.

The detection is regex-based, on a sliding window of recent output, plus an idle-output watchdog as a backstop:

- **Regex match.** A sliding 4 KB window of the captured output is checked for known prompt patterns (`[sudo] password for`, `Password:` at end of line, `doas (...) password:`, `Sorry, try again`, `sudo: a terminal is required`, ...). Strong signal, fires immediately, very low false-positive risk because the patterns are specific. `LC_ALL=C` is forced on the remote side so prompts are predictable.
- **Idle-output watchdog.** No chunks received for N seconds while the child is still alive. Default 90s — generous enough that apt downloads and brew from-source compiles don't trip it. `PLAYBASH_STDIN_WATCH_TIMEOUT=0` disables; any positive integer overrides the default.

On detection: SIGTERM the entire process group, then SIGKILL after a 5-second grace period. The host's status word becomes either `needs sudo` (regex matched) or `stuck (idle)` (threshold tripped). In the summary the host shows as a failure (✗), but with the distinct status word so the user can tell it apart from a real non-zero exit. Surfaced per-host so a daily run across many hosts produces a clean "these N hosts need you" list rather than a wall of stderr.

The original v2 plan called for a Linux-only precise path inspecting `/proc/$pid/wchan` to flag descendants blocked in `tty_read` / `n_tty_read`. It was deferred during dogfooding — the cheap regex path turned out to catch every prompt we hit in practice, and the precise path's added complexity wasn't justified.

#### The Mac PTY bugs (resolved during milestone 11)

Two subtle bugs in `playbash-wrap.py` had to be fixed before the kill path actually propagated end-to-end against Mac targets. The wrapper itself is platform-agnostic, but Mac/Darwin behaves differently from Linux in two ways that matter here. Full debugging trail in [playbash-debugging.md](./playbash-debugging.md).

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

See [`tty-simulation.md`](./tty-simulation.md) for additional background on the `script(1)`/`tee` pattern.

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
- Dependency graph: entry → all three playbash modules; sidecar → render (for `COLOR`). No cycles.

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
