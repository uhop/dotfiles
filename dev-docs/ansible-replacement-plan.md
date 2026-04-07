# Ansible replacement — implementation plan

Companion to [ansible-replacement.md](./ansible-replacement.md). This plan is a v1 proof-of-concept, intentionally minimal.

## Gate: evaluate `pyinfra` first

Before any code is written, evaluate [`pyinfra`](https://pyinfra.com/) against current Ansible usage. Outcome decides the rest of the plan:

- **Covers needs** → adopt it; this plan is shelved or reduced to a thin reporting wrapper.
- **Close but missing pieces** → adopt it and build only the missing bits on top.
- **Doesn't fit** → proceed with everything below.

Everything that follows assumes the third outcome.

## Shape

- **Runner**: Node (single CLI, minimal deps). Handles inventory, connection lifecycle, sidecar collection, live output rendering, and the final summary.
- **Playbooks**: `bash` scripts that source a small `tether.sh` helper providing `tether_warn`, `tether_action`, `tether_info`, etc. Playbooks stay readable and debuggable in isolation.
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
tether run <playbook> <host>            # run one playbook on one host
tether debug <playbook> <host>          # same, but stream raw output
tether list                             # list playbooks
tether hosts                            # list inventory entries
```

Playbooks live in a fixed directory (e.g. `~/.config/tether/playbooks/*.sh`). Inventory in a fixed file (e.g. `~/.config/tether/inventory.json`).

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

v1 uses **Option A**: tether does not manage ssh control sockets at all. It just shells out to `ssh`, `rsync`, and `sftp`. The user's existing `~/.ssh/config` already enables multiplexing globally, so the first call opens a master under `~/.ssh/sockets/`, subsequent calls reuse it, and `ControlPersist` cleans up.

Consequences:
- Tether's helpers stay trivial — no `-S`, no `-M`, no lifecycle code.
- Any interactive `ssh host` before or after a tether run also benefits from the warm master. This is a feature.
- Tether cannot forcibly close the master and must not try to (`ssh -O exit` would also kill unrelated sessions sharing the socket).
- A playbook longer than `ControlPersist` (5 min) is still fine — the master stays alive while connections are active; `ControlPersist` only counts idle time.

Revisit if any of these become true: parallel fan-out across hosts, playbooks where deterministic teardown matters, or users without `ControlMaster auto` in their ssh config. The fallback is a private `/tmp/tether.XXXX/` socket directory owned by tether (Option C in the discussion).

## Runtime model

For each `(playbook, host)`:

1. **Allocate remote scratch.** `ssh "$host" -- mktemp -d` to get a working directory on the target.
2. **Stage helpers.** `rsync` (or `sftp`) `tether.sh` into the scratch dir.
3. **Stage playbook.** Same, for the playbook script.
4. **Run playbook.** `ssh "$host" -- env TETHER_*=... bash "$scratch/playbook.sh"`, with the local side wrapping it in `script` to obtain a PTY. Exports:
   - `TETHER_HOST`, `TETHER_SCRATCH`
   - `TETHER_REPORT` — path to the remote sidecar file
   - `TETHER_HELPERS` — path to `tether.sh` so the playbook can `source "$TETHER_HELPERS"`
5. **Capture output.** Runner reads the PTY stream, keeps a rolling buffer of the last N lines (default 5), renders them as a fixed-height rectangle with ANSI cursor controls. Full stream is also tee'd to a per-run log file on the local side.
6. **Collect sidecar.** When the playbook exits, download `$TETHER_REPORT` via `rsync`/`sftp`. Parse it.
7. **Clean up remote scratch.** `ssh "$host" -- rm -rf "$scratch"`. The ssh master is left to `ControlPersist`.
8. **Render summary.** Status line + grouped warnings / actions / errors.

A non-zero exit from the playbook is a hard failure. Warnings and suggested actions are *always* communicated through the sidecar, never through exit codes — this is the explicit lesson from the discussion.

## Sidecar protocol (detailed)

The sidecar is a single file on the remote host whose path is in `$TETHER_REPORT`. The playbook (via helpers) appends one JSON object per line. JSON-lines is chosen for: append-safety, partial-read tolerance, and trivial parsing.

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

### Helper API (`tether.sh`)

```bash
tether_info  "installed 12 packages"
tether_warn  "disk usage above 80%" --target /var
tether_action reboot "kernel updated to 6.17.2"
tether_error "could not restart nginx, continuing"
tether_step  "package-upgrade"          # sets $TETHER_STEP for subsequent events
tether_data  '{"packages": 12}'         # attached to the next event
```

Each helper writes one line to `$TETHER_REPORT` with a flock for safety. Helpers must never fail the playbook — they swallow their own errors and write to `stderr` if the report file is unwritable.

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
- Always also write the full uncut stream to `~/.cache/tether/runs/<timestamp>-<host>-<playbook>.log`.

See [`tty-simulation.md`](./tty-simulation.md) and `./private_dot_local/libs/bootstrap.sh` for the `script`/`tee` background.

## Repository layout (proposed)

```
private_dot_local/
  libs/
    tether.sh                  # helper sourced by playbooks
  bin/
    executable_tether          # Node CLI entrypoint (or shim)
  share/
    tether/
      runner/                  # Node sources
        index.js
        connection.js          # ssh control-socket lifecycle
        runner.js              # run / debug commands
        sidecar.js             # JSON-lines parser + aggregator
        render.js              # PTY rectangle renderer
        inventory.js           # JSON loader
      playbooks/               # example playbooks (upd, etc.)
```

Exact paths to be confirmed against existing chezmoi conventions before coding.

## Milestones

1. **pyinfra evaluation.** Decision recorded in this file. *Blocks everything below.*
2. **Walking skeleton.** `tether run` against one host, executes a hardcoded `echo` playbook, prints raw output, cleans up the remote scratch dir.
3. **Helpers + sidecar.** `tether.sh` helpers, JSON-lines append, post-run download and parse, basic summary.
4. **PTY rectangle renderer.** Last-N-lines live view with full log on disk.
5. **Inventory + CLI polish.** JSON inventory, `tether list`, `tether hosts`, `tether debug`.
6. **Port one real playbook** (`upd`) and dogfood it. Record what hurts.
7. **Decide on v2 scope** based on dogfooding (parallel fan-out, groups, interactive prompts).

## Open questions to revisit before milestone 2

- Exact Node entrypoint shape under chezmoi (single bundled file vs. `node_modules`).
- Whether the helper should also be uploaded once and cached, or shipped per run (per run is simpler for v1).
