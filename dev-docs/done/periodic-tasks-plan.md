# Periodic tasks — implementation plan

See [periodic-tasks-design.md](../periodic-tasks-design.md) for problem
statement, constraints, scheduler research, and rationale.

## Language

| Piece | Language | Why |
|-------|----------|-----|
| Sidecar events for stuck detection | Node | Already in `runner.js` |
| Notification summary formatter | Node | Reuses `sidecar.js` primitives |
| `@self` pseudo-host | Node | Target resolver in `inventory.js` / `runner.js` |
| Generic notification wrapper | Bash | Leaf script |
| Playbash notification wrapper | Bash | Leaf script |
| `setup-periodic` utility | Bash | Creates platform-specific config |
| systemd units / launchd plists | Declarative config | Chezmoi templates |

## Status

- Phase 1a (sidecar events): **done** — `runner.js` emits action-level
  events for needs-sudo, wrong-password, stuck-idle.
- Phase 1b (`--report` flag): **done** — plain-text formatters in
  `sidecar.js`, threaded through runner and entry point, completions
  updated.
- Phase 1c (`@self`): **done** — resolves to local hostname in
  `inventory.js`, survives `filterSelf`, skips SSH precheck, works in
  mixed target lists. Version bumped to 3.4.0.
- Phase 2a (email-notify@): **done** — `email-notify@.service` template
  unit + `notify-systemd-failure` script. `.chezmoiignore` skips on macOS.
- Phase 2b (notify-on-failure): **done** — generic wrapper for
  launchd/cron.
- Phase 2c (notify-playbash): **done** — playbash wrapper, emails if
  actionable.
- Phase 3 (setup-periodic): **done** — options.bash utility, creates
  systemd timers / launchd plists, prerequisite checks, --list/--remove.
- Phase 4 (docs): **done** — AGENTS.md, ARCHITECTURE.md, llms.txt,
  README.md, wiki page updated.

---

## Phase 1c: `@self` pseudo-host (Node)

A built-in target name that resolves to the current host. Implemented in
the target resolver so all subcommands get it automatically.

Behavior:
- `@self` in the target list resolves to a synthetic target with the
  actual system hostname (`os.hostname()`) and a local address.
- Implies `--self` — `filterSelf` never removes `@self` entries.
- Works in mixed lists: `playbash run @self,host2 daily`.
- Display uses the real hostname, not `@self`.

Where to implement:
- `inventory.js` `resolveTargets()` — detect `@self` in the target
  string, produce a synthetic `{name: hostname, address: 'localhost'}`
  entry with an `isSelf` flag.
- `runner.js` `filterSelf()` — respect the `isSelf` flag (never filter).
- Entry point USAGE text — document `@self`.
- `completion.bash` — add `@self` to target completions.

---

## Phase 2: wrappers + notification units (bash)

### 2a. systemd `email-notify@.service` + notify script

Template unit for generic task failure notification on Linux:

```ini
# ~/.config/systemd/user/email-notify@.service
[Unit]
Description=Email notification for %i

[Service]
Type=oneshot
ExecStart=%h/.local/bin/notify-systemd-failure %i
```

Notify script (`notify-systemd-failure`):
- Receives failed unit name as `$1`
- Reads `journalctl --user-unit="$1" -n 50`
- Formats subject + body
- Pipes to `sendmail`
- Exits 0 even if sendmail missing (warns to stderr)

### 2b. Generic `notify-on-failure` wrapper

For launchd/cron where there's no `OnFailure=`:

```bash
#!/usr/bin/env bash
# notify-on-failure CMD [ARGS...]
# Runs CMD. On non-zero exit, captures output and sends email.
```

- Captures stdout+stderr of the command to a temp file
- Checks exit code
- On failure: formats and pipes to `sendmail`
- On success: silent. Temp file removed.

### 2c. Playbash notification wrapper

For playbash tasks on all platforms:

```bash
#!/usr/bin/env bash
# notify-playbash PLAYBOOK TARGETS [PLAYBASH-ARGS...]
# Runs playbash run --report. Sends email if actionable.
```

- Runs `playbash run "$targets" "$playbook" --report`
- Captures stdout (the report) to a variable
- If exit non-zero OR report non-empty → sends email
- On clean success → silent
- Replaces `OnFailure=` for playbash services (the wrapper handles it)
- Works for both local (`@self`) and fan-out targets

---

## Phase 3: `setup-periodic` utility (bash)

Standalone generic utility, manual opt-in. Uses `options.bash` for option
parsing, help, and output.

### Prerequisites check

Before creating any scheduler config, `setup-periodic` checks:
1. `sendmail` in PATH → if missing, fail with platform-specific install
   instructions (e.g., `apt install msmtp msmtp-mta` on Debian,
   `brew install msmtp` on macOS).
2. `~/.msmtprc` exists → warn if missing (sendmail binary exists but may
   not be configured).

### Interface sketch

```bash
setup-periodic daily "playbash run @self daily --report"
setup-periodic weekly "playbash run @self weekly --report"
setup-periodic daily "playbash push unmanaged daily-script --report"
setup-periodic daily "/path/to/backup-script" --email ops@example.com
setup-periodic --remove daily
setup-periodic --list
```

Options:
- `--email ADDRESS` — notification recipient. Default: chezmoi's configured
  email (`chezmoi data --format json | jq -r '.email'`).
- `--time HH:MM` — time of day to run (default: 04:00).
- `--days` — days to run. `daily` implies Mon-Sat, `weekly` implies Sun.
  Overridable.
- `--remove` — disable and remove a scheduled task.
- `--list` — show active periodic tasks with next-fire time.

Default schedule for playbash maintenance:
- daily: Mon-Sat at 04:00 CST
- weekly: Sun at 04:00 CST

### Fleet-wide setup

On managed Linux hosts (no sudo needed):
```bash
playbash exec all -- setup-periodic daily \
  "playbash run @self daily --report"
```

On macOS hosts: `setup-periodic` needs sudo for system daemons. The sudo
nesting with `playbash exec --sudo` needs testing. If problematic, set up
macOS hosts manually via SSH. Document this.

Unmanaged hosts don't get local timers — use operator fan-out instead.

### Logic

1. Detect platform (systemd vs launchd).
2. Check prerequisites (sendmail, msmtprc).
3. Determine wrapper: if command starts with `playbash` → playbash
   wrapper. Otherwise → generic (systemd `OnFailure=` or
   `notify-on-failure` wrapper depending on platform).
4. **Linux:**
   - Generate `.service` + `.timer` in `~/.config/systemd/user/`.
   - `loginctl enable-linger` (no sudo).
   - `systemctl --user daemon-reload && systemctl --user enable --now`.
5. **macOS:**
   - Generate plist with `UserName`, `StandardOutPath`, `StandardErrorPath`.
   - Explain sudo requirement, then `sudo cp` to `/Library/LaunchDaemons/`.
   - `sudo launchctl load <plist>`.
6. Print summary of what was created.

### `--remove` / `--list`

- `--remove`: disable timer/unload plist, remove files. Explain sudo on
  macOS before prompting.
- `--list`: show active periodic tasks with next-fire time.

---

## Phase 4: documentation

Wiki page covering:
- How local timers work (the primary pattern)
- How operator fan-out works (for unmanaged hosts)
- Manual systemd timer setup (for those who prefer hand-editing)
- Manual launchd system daemon setup
- Manual cron setup (fallback)
- msmtp installation and config per platform
- Other notification channels (ntfy, Slack, Pushover, Healthchecks.io)
- How the notification wrappers work
- `setup-periodic` usage
- Running `playbash-daily` directly: possible but no enhanced reporting
- macOS fleet setup limitations (sudo nesting)

---

## Phase ordering and dependencies

```
Phase 1a (sidecar events)  ── done
Phase 1b (--report flag)   ── done
                                    ├── Phase 2c (playbash wrapper) ──┐
Phase 1c (@self)           ────────┘                                  │
                                                                      ├── Phase 3 (setup-periodic)
Phase 2a (email-notify@)   ──────────────────────────────────────────┤
Phase 2b (notify-on-failure) ────────────────────────────────────────┘

Phase 4 (docs) can proceed in parallel with any phase.
```
