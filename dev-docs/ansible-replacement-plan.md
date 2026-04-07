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
- Connect / run / upload / download / close.
- Sidecar event collection (post-hoc, see below).
- Live "last N lines" output rectangle via PTY capture.
- Per-host summary at end with warnings, suggested actions, and errors.
- A trivial new inventory format (see below).
- A debug runner that streams everything verbatim against a single host.

Out (deferred to v2+):
- Parallel fan-out across hosts.
- Groups, tags, host patterns beyond a flat list.
- Idempotency primitives.
- Interactive "do you want to reboot now?" prompts (just *report* the suggestion in v1).
- Extraction into a standalone project.

## CLI surface

```
playbash run <playbook> <host>            # run one playbook on one host
playbash debug <playbook> <host>          # same, but stream raw output
playbash list                             # list playbooks
playbash hosts                            # list inventory entries
```

Playbooks live in a fixed directory (e.g. `~/.config/playbash/playbooks/*.sh`). Inventory in a fixed file (e.g. `~/.config/playbash/inventory.json`).

## Inventory format (v1)

Plain JSON, flat object. Chosen because `jq` is already installed everywhere we care about, Node parses it natively (no extra dep), and it's the same format as the sidecar — one parser to learn. Groups can come later.

```json
{
  "web1": { "address": "web1.example.com", "user": "eugene", "port": 22 },
  "db1":  { "address": "10.0.0.5" }
}
```

Any field beyond `address` falls through to `~/.ssh/config`.

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

- Spawn the remote command under a PTY so utilities like `apt`, `dnf`, progress bars etc. behave as on a terminal.
- Maintain a ring buffer of the last N lines (default 5, configurable).
- Re-render the rectangle in place using ANSI cursor save/restore + clear-to-end-of-line. Wrap/truncate long lines to terminal width.
- On exit, clear the rectangle and print the final status line.
- Always also write the full uncut stream to `~/.cache/playbash/runs/<timestamp>-<host>-<playbook>.log`.

See [`tty-simulation.md`](./tty-simulation.md) and `./private_dot_local/libs/bootstrap.sh` for the `script`/`tee` background.

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

1. **Walking skeleton.** `playbash run` against one host, executes a hardcoded `echo` playbook, prints raw output, cleans up the remote scratch dir.
2. **Helpers + sidecar.** `playbash.sh` helpers, JSON-lines append, post-run download and parse, basic summary.
3. **PTY rectangle renderer.** Last-N-lines live view with full log on disk.
4. **Inventory + CLI polish.** JSON inventory, `playbash list`, `playbash hosts`, `playbash debug`.
5. **Port one real playbook** (`upd`) and dogfood it. Record what hurts.
6. **Decide on v2 scope** based on dogfooding (parallel fan-out, groups, interactive prompts).

## Reboot/warning reporting in `upd`/`cln`

`upd` and `cln` already format their reboot recommendations and warnings using `options.bash` (see `../options.bash/`). Rather than sprinkling `playbash_action`/`playbash_warn` calls inline, factor the existing print logic into a single helper function that:

- Always prints the formatted message locally (current behavior).
- *Additionally*, when `$PLAYBASH_REPORT` is set, appends a structured event to the sidecar.

This keeps the scripts runnable by hand exactly as today and gives the runner machine-readable events for free. Implementation deferred — not part of v1 milestones.

## Open questions to revisit before milestone 2

- Exact Node entrypoint shape under chezmoi (single bundled file vs. `node_modules`).
- Exact regex set for prompt detection, and the idle-output threshold N.
- Whether the v2 precise stdin-wait detector should be a per-host watchdog (one persistent connection inspecting `/proc`) or a per-tick poll.

