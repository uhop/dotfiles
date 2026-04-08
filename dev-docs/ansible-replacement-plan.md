# Ansible replacement — implementation plan

Companion to [ansible-replacement.md](./ansible-replacement.md). This plan is a v1 proof-of-concept, intentionally minimal.

## Gate: `pyinfra` evaluated — rejected

[`pyinfra`](https://pyinfra.com/) was evaluated against current usage and ruled out. Reasons (see [ansible-replacement.md](./ansible-replacement.md#addendum-pyinfra)):

- Operations abstraction (apt/apk/brew/zfs/...) is overkill — we only want to run existing shell commands.
- Step-synchronized fan-out across hosts; we want each host to run independently, in isolation.
- Playbooks are specialized Python modules and cannot be executed directly as scripts; we want plain shell files that remain runnable by hand for debugging.

Proceeding with the plan below.

## Shape

- **Runner**: Node (single CLI, minimal deps). Handles inventory, connection lifecycle, sidecar collection, live output rendering, and the final summary.
- **Playbooks**: `bash` scripts living in `~/.local/bin/`, distributed via chezmoi to every managed host, sourcing a small `playbash.sh` helper from `~/.local/libs/`. Helpers provide `playbash_warn`, `playbash_action`, `playbash_info`, etc. Playbooks stay readable, debuggable in isolation, and *directly runnable by hand* over plain `ssh` without setting any playbash-specific env vars — sidecar reporting activates only when `$PLAYBASH_REPORT` is set by the runner.
- **Transport**: plain `ssh` / `rsync` / `sftp`. Connection multiplexing is delegated entirely to the user's existing `~/.ssh/config` (`ControlMaster auto`, `ControlPath ~/.ssh/sockets/%r@%h-%p`, `ControlPersist 5m`). See [Connection management](#connection-management) below.

## v1 scope (proof of concept)

In:
- One host at a time, sequential execution.
- Run preinstalled playbooks (chezmoi-deployed to `~/.local/bin/playbash-*`) over ssh.
- Sidecar event collection (post-hoc, see below).
- Live "last N lines" output rectangle via PTY capture; `-n 0` opts out.
- Per-host summary at end with warnings, suggested actions, and errors.
- JSON inventory at `~/.config/playbash/inventory.json`. Self detection by IP at runtime — no marker file.
- `playbash list` / `playbash hosts` / `playbash debug` (raw streaming + verbose).
- Local execution on the self host via `--self`.

Out (deferred to v2+):
- Parallel fan-out across hosts.
- Groups, tags, host patterns beyond a flat list (schema reserved; CLI deferred).
- Upload / download mode for ad-hoc playbooks not yet in the chezmoi tree.
- Idempotency primitives.
- Interactive "do you want to reboot now?" prompts (just *report* the suggestion in v1).
- Extraction into a standalone project.

## CLI surface

```
playbash run   <playbook> <host> [-n N] [--self]   # run one playbook on one host
playbash debug <playbook> <host> [--self]          # same, but raw output + verbose
playbash list                                      # list playbooks
playbash hosts                                     # list inventory entries
```

Playbooks live at `~/.local/bin/playbash-*` on every managed host (deployed by chezmoi). Inventory at `~/.config/playbash/inventory.json`. Self detection is runtime by IP comparison — no marker file.

## Inventory

Plain JSON, flat object. Chosen because Node parses it natively (no extra dep) and it's the same format as the sidecar — one parser to learn. Lives at `~/.config/playbash/inventory.json`, deployed identically to every managed host via chezmoi (`dot_config/playbash/inventory.json`).

### Schema

A value in the top-level object is one of:

- **String** — host address shorthand. `"web1": "web1.example.com"` is sugar for `{"address": "web1.example.com"}`.
- **Object with `address`** — host with extra attributes. Anything beyond `address` (`user`, `port`, ...) is currently informational; ssh-side overrides should live in `~/.ssh/config`.
- **Array of strings** — group. Members are host names. Loaded by the parser today, listed by `playbash hosts`, but not yet resolvable on the CLI; using one as a host argument is rejected with a clear error. Groups land in a later milestone (see [Groups (future)](#groups-future)).

```json
{
  "web1":      "web1.example.com",
  "db1":       { "address": "10.0.0.5", "user": "eugene", "port": 2222 },
  "mac":       "mac.local",
  "databases": ["db1"]
}
```

### Host argument resolution

When the user passes a host name, the runner looks it up in the inventory:

- **Found, host entry** → use the inventory's `address` for ssh; keep the inventory name for display, log filenames, and `$PLAYBASH_HOST`.
- **Found, group entry** → reject with "groups not yet supported" (until the groups milestone lands).
- **Not found** → pass the literal string to ssh, so `~/.ssh/config` aliases keep working unchanged. The inventory is purely additive.

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

### Groups (future)

Deferred to a later milestone (after dogfooding `upd`/`cln`). Design is fixed now so milestone-4 inventories don't need to migrate:

- **Schema:** array values in `inventory.json` (already accepted by the parser).
- **CLI:** comma-separated host targets, mixing host and group names: `playbash run upd db1,web,prod`. Resolution flattens to a unique ordered set of host names.
- **Recursion:** groups are flat lists of *host* names. No groups-of-groups in v1 — keeps the mental model and dedup logic simple. Revisit only if real use demands it.
- **`all`:** implicit group, equals every host entry in the inventory. Not stored; computed.
- **Self exclusion:** any list, however constructed (group, ad-hoc comma-separated CLI list, `all`), silently drops the self host by default. `--self` flips this for the entire invocation. Explicitly naming self as a single argument still requires `--self` (consistent with single-host behavior).
- **Parallel fan-out:** lands together with groups. A serial walk over many hosts would be worse than running them by hand; the two features only make sense together.

## Connection management

v1 uses **Option A**: playbash does not manage ssh control sockets at all. It just shells out to `ssh`, `rsync`, and `sftp`. The user's existing `~/.ssh/config` already enables multiplexing globally, so the first call opens a master under `~/.ssh/sockets/`, subsequent calls reuse it, and `ControlPersist` cleans up.

Consequences:
- Playbash's helpers stay trivial — no `-S`, no `-M`, no lifecycle code.
- Any interactive `ssh host` before or after a playbash run also benefits from the warm master. This is a feature.
- Playbash cannot forcibly close the master and must not try to (`ssh -O exit` would also kill unrelated sessions sharing the socket).
- A playbook longer than `ControlPersist` (5 min) is still fine — the master stays alive while connections are active; `ControlPersist` only counts idle time.

Revisit if any of these become true: parallel fan-out across hosts, playbooks where deterministic teardown matters, or users without `ControlMaster auto` in their ssh config. The fallback is a private `/tmp/playbash.XXXX/` socket directory owned by playbash (Option C in the discussion).

## Runtime model

Playbooks are expected to already live on the target host, distributed by `chezmoi` to the same conventional locations as everything else: scripts in `~/.local/bin/` and sourced helpers (including `playbash.sh`) in `~/.local/libs/`. This is the **primary mode**. It mirrors how `upd`, `cln`, `dcm`, and the existing `ansible-daily` are deployed today, and it has two important properties:

- The playbook script is *directly runnable by hand* over plain `ssh` with no environment setup. Helpers locate their siblings via a relative path (`../libs/playbash.sh`). Sidecar reporting is opt-in: if `$PLAYBASH_REPORT` is unset, the helpers print human-readable output and skip the JSON-lines append.
- Playbash does not need to copy anything for the common case. It only sets a few env vars and runs the script.

A secondary **upload mode** exists for ad-hoc playbooks not yet in the chezmoi tree (e.g. a one-off written this morning). It stages the playbook into a remote `mktemp -d` scratch dir and runs it from there. Helpers are *not* uploaded in this mode either — they are expected to already be in `~/.local/libs/` on every managed host. If a target host lacks the helpers, that's a hard error reported up front.

### Primary mode (preinstalled playbook)

For each `(playbook, host)`:

1. **Resolve playbook path.** Look up `playbook` in the local registry → resolves to a path like `~/.local/bin/playbook-foo`. Playbash assumes the same path exists on the target (chezmoi guarantee).
2. **Run playbook.** `ssh "$host" -- env PLAYBASH_*=... LC_ALL=C bash -lc '~/.local/bin/playbook-foo'`, with the local side wrapping it in `script` to obtain a PTY. Exports:
   - `PLAYBASH_HOST`
   - `PLAYBASH_REPORT` — path to a remote sidecar file (under `~/.cache/playbash/` or `mktemp`)
3. **Capture output.** Runner reads the PTY stream, keeps a rolling buffer of the last N lines (default 5), renders them as a fixed-height rectangle with ANSI cursor controls. Full stream is also tee'd to a per-run log file on the local side.
4. **Watch for stdin waits.** See [Interactive input detection](#interactive-input-detection) below.
5. **Collect sidecar.** When the playbook exits, download `$PLAYBASH_REPORT` via `rsync`/`sftp`. Parse it. Delete the remote sidecar.
6. **Render summary.** Status line + grouped warnings / actions / errors.

The ssh master is left to `ControlPersist`.

### Upload mode (ad-hoc playbook)

Same as above, but inserts two extra steps before step 2:

1a. **Allocate remote scratch.** `ssh "$host" -- mktemp -d`.
1b. **Stage playbook.** `rsync` (or `sftp`) the playbook into the scratch dir.

And after step 5:

5a. **Clean up remote scratch.** `ssh "$host" -- rm -rf "$scratch"`. Also runs on the interactive-input abort path.

A non-zero exit from the playbook is a hard failure. Warnings and suggested actions are *always* communicated through the sidecar, never through exit codes — this is the explicit lesson from the discussion.

### Interactive input detection

Some commands (notably `chezmoi update` when it needs to install system packages) sporadically drop into a `sudo` password prompt. More generally, *any* prompt for stdin is a problem under playbash: the playbook has no tty for the user and would just hang.

The eventual model is to treat any wait on stdin as a ground for termination, not just a password prompt. v1 ships with the cheap path and a clearly marked extension point for the precise path.

**v1 (cheap, cross-platform):**

- Regex over the captured PTY stream for known prompt patterns (`[sudo] password for `, `Password:` at end of line, `[Y/n]`, `Are you sure? `, etc.).
- Idle-output watchdog: if the PTY produces no bytes for N seconds and the remote process is still alive, escalate to the same handling as a regex match. N is generous (e.g. 60s) to avoid false positives on slow downloads. Force `LC_ALL=C` on the remote side so prompts are predictable.

**v2 (precise, Linux-only):**

- A tiny watchdog colocated on the host (or per-tick `ssh` probe) inspects `/proc/$pid/wchan` (or `/proc/$pid/stack`) and flags any descendant blocked in `tty_read` / `n_tty_read`. This is unambiguous — no regex, no timing heuristics. macOS falls back to v1.

On a match (either path):

1. Send EOF / kill the remote process so it fails fast instead of hanging.
2. Clean up: delete the remote sidecar; in upload mode, also remove the remote scratch dir. Manual re-run over `ssh` will recreate whatever it needs.
3. Mark the host's outcome as a distinct status — `needs interactive input` (with a sub-reason `sudo` when the regex caught a sudo prompt) — *not* a generic failure.
4. Surface it as its own line in the summary, louder than a normal error, with the suggestion to re-run the playbook manually over `ssh`.

This status is reported per host so the daily run across many hosts produces a clean "these N hosts need you" list rather than a wall of stderr.

## Sidecar protocol (detailed)

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

- `info` — progress note worth keeping in the summary (e.g. "installed 12 packages"). Not surfaced unless `--verbose`.
- `warn` — something the user should know but no action needed.
- `action` — something the user *should do* after the run; `kind` is required and machine-readable so the runner can aggregate ("3 hosts need reboot").
- `error` — non-fatal error the playbook chose to record and continue past. Fatal errors are conveyed by exit code + captured stderr, not the sidecar.

### Helper API (`playbash.sh`)

```bash
playbash_info  "installed 12 packages"
playbash_warn  "disk usage above 80%" --target /var
playbash_action reboot "kernel updated to 6.17.2"
playbash_error "could not restart nginx, continuing"
playbash_step  "package-upgrade"          # sets $PLAYBASH_STEP for subsequent events
playbash_data  '{"packages": 12}'         # attached to the next event
```

Each helper writes one line to `$PLAYBASH_REPORT` with a flock for safety. Helpers must never fail the playbook — they swallow their own errors and write to `stderr` if the report file is unwritable.

### Aggregation in the summary

The runner groups events by `level` and, for actions, by `kind`. Example output:

```
host web1.example.com: ok (12.3s)
  actions:
    reboot — kernel updated to 6.17.2
  warnings:
    /var: disk usage above 80%
```

When v2 adds parallel fan-out, the same aggregation runs across hosts: "2 hosts need reboot: web1, db1".

## Live output rendering

- Spawn the remote command under a PTY so utilities like `apt`, `dnf`, progress bars etc. behave as on a terminal. The PTY is allocated **on the target** by `script(1)`, not locally via `ssh -tt`. See [Remote PTY via script(1)](#remote-pty-via-script1) below.
- Maintain a ring buffer of the last N lines (default 5, configurable via `-n`, set `-n 0` to disable the rectangle and stream sanitized output raw).
- Re-render the rectangle in place using ANSI cursor save/restore + clear-to-end-of-line. Wrap/truncate long lines to terminal width.
- Treat `\r\n` as a single line ending; only treat lone `\r` as a progress-bar line reset. PTY-translated streams use `\r\n`, so getting this wrong wipes every line before commit.
- Strip terminal-hostile escape sequences (cursor positioning, OSC, DCS, CPR queries, alt-screen, ...) from the byte stream **before** display, in *both* rectangle and raw modes. Keep SGR (color) escapes. The full uncut stream still goes to the log file.
- On exit, clear the rectangle and print the final status line.
- Always also write the full uncut stream to `~/.cache/playbash/runs/<timestamp>-<host>-<playbook>.log`. Use `playbash log [path]` to view a log safely (sanitized) — direct `cat` of a log file may inject control characters into the user's terminal.

See [`tty-simulation.md`](./tty-simulation.md) and `./private_dot_local/libs/bootstrap.sh` for the `script`/`tee` background.

### Remote PTY via script(1)

The runner wraps the remote command in `script -qfec '<cmd>' /dev/null` (util-linux syntax) and runs it through ssh **without** `-tt`. ssh has plain pipes locally on both sides; the PTY is allocated by `script` on the target. Rationale, surfaced during milestone-5 dogfooding:

- With `ssh -tt`, terminal queries from remote tools (OSC 11 background-color, CPR `\x1b[6n`, etc.) flow back through ssh into the **local** terminal, which generates responses, which are written to Node's stdin, which we never read, which sit in the terminal's input buffer until Node exits — at which point the user's shell reads them as typed input (visible as ANSI gibberish at the prompt).
- With remote `script(1)`, the queries are answered (or simply not asked) by the remote PTY. They never reach the local terminal. Bug eliminated.
- Stdout and stderr of the inner command are merged in the remote PTY; both arrive on ssh's stdout. Plain ssh stderr (e.g. "Shared connection closed") still arrives on stderr and goes to the log only.
- This is "Option D" from the milestone-3 PTY discussion. It was deferred there for simplicity; promoted in milestone 5 once the bug bit.

**Target OS:** util-linux `script(1)`. Linux-only for now. macOS uses BSD `script` with different argument syntax — deferred until someone wants to run a remote playbook against the Mac. Local execution on the Mac via `--self` does *not* go through `script` and works today.

## Repository layout (proposed)

```
private_dot_local/
  libs/
    playbash.sh                  # helper sourced by playbooks (deployed to every host by chezmoi)
  bin/
    executable_playbash          # Node CLI entrypoint (or shim) — local only
    executable_playbook-*      # playbook scripts, deployed to every host by chezmoi
  share/
    playbash/
      runner/                  # Node sources — local only
        index.js
        runner.js              # run / debug commands
        sidecar.js             # JSON-lines parser + aggregator
        render.js              # PTY rectangle renderer
        inventory.js           # JSON loader
        stdin-watch.js         # interactive-input detection
```

Note that playbooks and `playbash.sh` are deployed to *every* managed host via the existing chezmoi flow. The runner sources (`share/playbash/runner/`) are local-only — they live on the operator's machine. There is no `connection.js` because connection lifecycle is delegated to `~/.ssh/config` (see [Connection management](#connection-management)).

Exact paths to be confirmed against existing chezmoi conventions before coding.

## Milestones

### Done (v1)

1. **Walking skeleton.** ✅ `playbash run echo localhost` against a hardcoded inline `echo` over ssh, then a real preinstalled `playbash-hello` script invoked via `ssh host -- ~/.local/bin/playbash-hello`. Per-run log file, status line, exit-code propagation.
2. **Helpers + sidecar.** ✅ `playbash.sh` with `playbash_info`/`warn`/`error`/`action`/`reboot`/`step`. JSON-lines sidecar at a randomly-named `/tmp` path on the remote, fetched in one extra ssh round trip after the playbook exits. Per-host summary grouped by level. Pretty-print fallback to stderr when `$PLAYBASH_REPORT` is unset (manual debugging).
3. **PTY rectangle renderer.** ✅ Last-N-lines live view with `-n LINES` (default 5, `-n 0` disables). Full uncut byte stream on disk.
4. **Inventory + CLI polish.** ✅ Subcommand dispatcher (`run`, `debug`, `list`, `hosts`). JSON inventory at `~/.config/playbash/inventory.json` with string/object/array shorthand. Inventory loader recognizes group entries (arrays) but rejects them as host args until groups land. `playbash list` globs `~/.local/bin/playbash-*`. `playbash hosts` aligned columns.
   1. **Sub-milestone 4.5.** ✅ Self detection by IP (`os.networkInterfaces()` + `dns.lookup`). `--self` flag opts in to local execution as a child process (no ssh) using the same Rectangle/sidecar/summary pipeline. `playbash hosts` marks self entries.
5. **Port one real playbook and dogfood it.** ✅ `playbash-daily` and `playbash-weekly` ported (orchestrate `chezmoi update`, `dcms`, `upd -y`/`upd -cy`). Linux-only post-hoc reboot detection via `playbash_reboot`. **Three real bugs found and fixed during dogfooding:**
   - Switched from `ssh -tt` to remote `script(1)` (Option D). Eliminated OSC/CPR query echo-back to the user's shell after the run.
   - Sanitizer that strips terminal-hostile escapes (cursor positioning, OSC, DCS, CPR) before display in *both* rectangle and raw passthrough modes; SGR colors preserved; raw bytes still go to the log.
   - Fixed `Rectangle.feed` to treat `\r\n` as a single line ending. PTY-translated streams use `\r\n`; the original lone-`\r` reset was wiping every line before commit, leaving the rectangle empty.
   - Added `playbash log [path]` subcommand for safely viewing log files (pipes through the same sanitizer).

### Next (v2 — priority order)

These are queued in the order locked in after milestone-5 dogfooding. We work on them top-down; each one is its own milestone with its own design pass.

6. **Output polish.** Color and tighter layout in the runner's per-host summary (status line, actions, warnings, errors). Has been waiting since milestone 2; now urgent because we're looking at the output every day. Smallest of the v2 items, immediately visible quality-of-life win.
7. **Groups + parallel fan-out.** The two ship together — sequential fan-out across many hosts is worse than running them by hand. CLI accepts comma-separated lists and group names; group definitions in the inventory (already parsed by the loader); implicit `all`; default self-exclusion with `--self` override. See [Groups (future)](#groups-future) and [Self host](#self-host) for the design.
8. **`upd`/`cln` refactor.** Factor reboot warnings into a function that does both `options.bash` formatting and a sidecar event. Includes the docker-ce-silent-break detection (when `apt` upgrades `docker-ce` and breaks docker without setting `/run/reboot-required` — caught manually during milestone-5 dogfooding on `croc`). See [Reboot/warning reporting in upd/cln](#rebootwarning-reporting-in-updcln).
9. **Interactive input detection.** Generic stdin-wait detection to catch the `chezmoi update`-needs-sudo case and similar. v1 cheap path: regex over output + idle-output watchdog with `LC_ALL=C`. v2 precise path: `/proc/$pid/wchan` inspection on Linux. macOS falls back to v1. See [Interactive input detection](#interactive-input-detection).
10. **macOS remote target support.** BSD `script(1)` syntax in the remote command wrap. Detect at first contact, cache per host. Lets you `playbash run daily <mac-host>` from any other machine. Local execution on the Mac via `--self` already works.

### Future (post-v2 — discussion needed)

Beyond the current plan. These are real wants flagged by the user and worth their own design conversations before coding.

- **Upload / download primitives.** Stage files to a host before running a playbook; pull files back after. Originally part of the "Possible alternative" section in [ansible-replacement.md](./ansible-replacement.md) but cut from v1 to keep scope tight. Needed for ad-hoc one-off playbooks not yet in the chezmoi tree, and for "fetch this log" workflows.
- **Run arbitrary commands.** A `playbash exec <host> <command...>` that wraps a one-shot command in the same sidecar/rectangle pipeline as a playbook. Useful for "run this on every server right now" without writing a playbook script first.
- **`sudo` support.** The unsolved problem from [ansible-replacement.md § Unsolved: sudo password](./ansible-replacement.md#unsolved-sudo-password). Currently we punt and assume scripts never ask. The right shape is unclear and worth a real design conversation before any code — the trade-offs around password handling, certificate-based sudo, sidecar-driven elevation, and detect-and-abort all need to be on the table together.
- **Bash completions.** Subcommands (`run`, `debug`, `list`, `hosts`, `log`), playbook names (glob `~/.local/bin/playbash-*`), host names (read from `~/.config/playbash/inventory.json`), `--self`/`-n`. The other CLIs in this repo expose a `--bash-completion` flag that prints a completion script — playbash should do the same so installation is `playbash --bash-completion >> ~/.bash_completion` or similar. Small enough to fold into any v2 milestone, but tracked here so it's not forgotten.

## Reboot/warning reporting in `upd`/`cln`

`upd` and `cln` already format their reboot recommendations and warnings using `options.bash` (see `../options.bash/`). Rather than sprinkling `playbash_action`/`playbash_warn` calls inline, factor the existing print logic into a single helper function that:

- Always prints the formatted message locally (current behavior).
- *Additionally*, when `$PLAYBASH_REPORT` is set, appends a structured event to the sidecar.

This keeps the scripts runnable by hand exactly as today and gives the runner machine-readable events for free.

**Status:** v1 deferred this. Milestone 5 added a thin post-hoc check in `playbash-daily`/`playbash-weekly` (`[ -e /run/reboot-required ]`) so the apt/snap reboot signal still surfaces in the runner's summary. The proper refactor is queued as v2 milestone 8.

**Docker-ce silent-break case (caught in milestone-5 dogfooding, confirmed twice).** When `apt` upgrades `docker-ce`, the docker daemon stops working properly (`docker compose up` fails with container conflicts) but no `/run/reboot-required` is created. The user has to know to reboot. The first occurrence on `croc` was diagnosed by manually rebooting and re-running `dcm`; a second occurrence was caught by the same pattern. This is now a confirmed real-world failure mode worth detecting automatically. Two ways:

- **Post-failure heuristic:** if `dcms` exited non-zero AND `dpkg.log` shows a recent `docker-ce` upgrade, emit `playbash_reboot "docker-ce upgraded; restart recommended"`. Fires only after a failure.
- **Pre-emptive:** parse `dpkg.log` after `upd` to see if `docker-ce` was just upgraded, and emit `playbash_reboot` proactively. Doesn't depend on `dcms` failing.

Both belong inside the v2 milestone-8 refactor of `upd`/`cln`, not in the playbash wrapper.

## Open questions

These are the remaining "decide before coding" items for the v2 work above.

- **Output polish (milestone 6):** color palette, status-line format, whether to fold the elapsed time into the host name line vs. a separate line, what the action/warning grouping looks like with multiple kinds.
- **Groups (milestone 7):** does the "list of hosts" type belong to the runtime (so the same code path serves `playbash run upd web1` and `playbash run upd web1,db1`) or stay as a fan-out wrapper around the existing single-host pipeline? Decision affects how parallelism is implemented.
- **Interactive input detection (milestone 9):** exact regex set for prompt detection, idle-output threshold N (likely 60s), whether the v2 precise stdin-wait detector should be a per-host watchdog (one persistent connection inspecting `/proc`) or a per-tick poll. `LC_ALL=C` already injected on the remote.
- **Node entrypoint shape:** still a single bundled file. Crossed the "should split" threshold during milestone-7 design (estimated ~940 lines after groups+fan-out lands), but the split is deferred to its own milestone *after* milestone 7 dogfoods clean. Splitting and adding a feature in the same change makes regression triage harder. Tracker: split into `inventory.js`, `render.js` (Rectangle + StatusBoard + COLOR), `sidecar.js` (parser + summary + aggregator), runner stays as the dispatcher.

