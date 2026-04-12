# Periodic tasks — implementation plan

See [periodic-tasks-design.md](./periodic-tasks-design.md) for problem
statement, constraints, scheduler research, and rationale.

## Language

| Piece | Language | Why |
|-------|----------|-----|
| Sidecar events for stuck detection | Node | Already in `runner.js` |
| Notification summary formatter | Node | Reuses `sidecar.js` primitives |
| Generic notification wrapper | Bash | Leaf script |
| Playbash notification wrapper | Bash | Leaf script |
| `setup-periodic` utility | Bash | Creates platform-specific config |
| systemd units / launchd plists | Declarative config | Chezmoi templates |

---

## Phase 1: playbash sidecar + report (Node)

### 1a. Emit sidecar events for stuck-process detection

The runner detects stuck processes (`stuckReason: 'sudo'`,
`'wrong password'`, `'idle'`) and sets `statusWord`, but does not write
sidecar events. Emit `action`-level events:

- `{level: "action", kind: "needs-sudo", msg: "…"}`
- `{level: "action", kind: "wrong-password", msg: "…"}`
- `{level: "action", kind: "stuck-idle", msg: "…"}`

Where: `runner.js`, around line 570 where `stuckReason` is set. The runner
already has access to `_playbash_emit`-equivalent logic (sidecar write).

### 1b. `--report` flag for plain-text notification summary

A `--report` flag on `playbash run` that writes a plain-text summary of
actionable events to stdout after the run completes. The terminal status
board already goes to stderr.

- If nothing actionable → empty stdout (no output).
- Exit code unchanged — wrapper checks report content to detect
  "succeeded but actionable" (no special exit code 2).
- Content: per-host actionable events, cross-host aggregation, pass/fail
  count, log paths.
- Reuses `parseSidecar`, `aggregateEvents` from `sidecar.js`. New
  plain-text renderer (no ANSI) alongside existing `renderSummary` /
  `renderAggregated`.

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
setup-periodic daily "playbash run all daily"
setup-periodic weekly "playbash run all weekly"
setup-periodic daily "/path/to/backup-script" --email ops@example.com
setup-periodic daily "playbash run all daily" --time 04:00
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
- Manual systemd timer setup (for those who prefer hand-editing)
- Manual launchd system daemon setup
- Manual cron setup (fallback)
- msmtp installation and config per platform
- Other notification channels (ntfy, Slack, Pushover, Healthchecks.io)
- How the notification wrappers work
- `setup-periodic` usage

---

## Phase ordering and dependencies

```
Phase 1a (sidecar events)  ──┐
                              ├── Phase 2c (playbash wrapper) ──┐
Phase 1b (--report flag)   ──┘                                  │
                                                                ├── Phase 3 (setup-periodic)
Phase 2a (email-notify@)   ────────────────────────────────────┤
Phase 2b (notify-on-failure) ──────────────────────────────────┘

Phase 4 (docs) can proceed in parallel with any phase.
```
