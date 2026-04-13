# Periodic tasks — design

## Problem

Maintenance scripts (system updates, docker refreshes, cleanup) run
manually today. On a fleet of always-on machines (servers, home-lab hosts)
they should run automatically with failure notifications. No one should
have to remember to run `upd` on six machines every day.

## Constraints

- **Target: always-on machines.** Not laptops — opening a laptop should not
  trigger catch-up updates that block immediate use.
- **Only notify on failure or actionable events.** Never on clean success.
- **Leverage built-in scheduler mechanisms.** systemd and launchd already
  handle scheduling, logging, failure detection, and overlap protection.
  Custom code only where the system falls short.
- **Minimal external dependencies.** msmtp (SMTP relay) is the only
  justified external dependency. Everything else is standard system tools,
  Node (already required by playbash), or bash.
- **Manual opt-in.** No automatic timer setup via chezmoi `run_once_*`.
  A setup utility the user runs explicitly.

## Dependencies

| Dependency | Status | Justification |
|---|---|---|
| systemd (Linux) | Standard | Every modern Linux server |
| launchd (macOS) | Standard | Built into macOS |
| journalctl, systemctl, loginctl | Standard | Part of systemd |
| launchctl | Standard | Part of macOS |
| flock | Standard | Part of `util-linux` (cron overlap) |
| curl | Standard | Only for optional channels (ntfy, Slack) |
| Node.js | Already required | playbash depends on it |
| bash 4+ | Already required | All utilities require it |
| **msmtp** | **External** | Lightweight SMTP relay. No reasonable alternative without writing one. Opt-in — not installed by default. |
| sendmail (binary) | Via msmtp | `msmtp-mta` provides `/usr/sbin/sendmail` |

No other external dependencies.

---

## Two-layer architecture

1. **Scheduler layer** (generic) — systemd timers or launchd run any
   command on a schedule. They capture logs and detect failure via exit
   code. This layer knows nothing about playbash.
2. **Application layer** (playbash-specific) — the playbash runner emits
   structured sidecar events and can produce a plain-text notification
   summary. This layer only adds value where the system can't know what
   happened (e.g., "all playbooks exited 0 but a host needs a reboot").

---

## Deployment patterns

### Managed hosts: local timers (primary)

Each managed host runs its own timer. The scheduled command is:

```
playbash run @self daily --report
```

This is self-contained: the host's own timer, its own msmtp, its own
notifications. No dependence on an operator machine being up.

`@self` is a built-in pseudo-host that resolves to the local hostname and
implies `--self`. It avoids hardcoding the hostname in timer configs,
making the same command work on every host.

Fleet-wide setup via playbash:
```bash
playbash exec all --sudo -- setup-periodic daily \
  "playbash run @self daily --report"
```

This works because `setup-periodic` is chezmoi-managed (deployed to
`~/.local/bin/` on every host).

**macOS caveat:** `setup-periodic` needs `sudo` on macOS to install system
daemons. When run via `playbash exec --sudo`, the sudo password injection
handles the outer `playbash exec` layer, but `setup-periodic` calling
`sudo` internally creates a nesting issue. Research/test whether the
injected password propagates. If not, set up macOS hosts manually via
SSH. Document this.

### Unmanaged hosts: operator fan-out

Unmanaged hosts (not in inventory, no chezmoi) don't have local timers.
An operator machine runs a timer that fans out to them:

```
playbash push unmanaged-hosts daily-script --report
```

This requires the operator machine to be available at run time — a single
point of failure, but acceptable for a handful of unmanaged hosts.

The fan-out report (cross-host aggregation) is needed for this pattern.

### Running playbooks directly (without the runner)

Running `playbash-daily` directly (instead of `playbash run @self daily`)
is possible, but loses:

- `--report` notification summary
- Stuck-process detection (sudo prompts, idle timeout)
- Sidecar event collection
- Log file capture and timing

For scheduled tasks, always use the `playbash run` form. Document in the
wiki that direct execution is possible but produces no enhanced reporting.

---

## `@self` pseudo-host

A built-in target name that resolves to the current host. Supported by
all subcommands (`run`, `push`, `debug`, `exec`, `put`, `get`).

Behavior:
- Resolves to the actual system hostname for display (reports and status
  lines show "think", not "@self").
- Implies `--self` — no need to pass the flag.
- Works in mixed target lists: `playbash run @self,host2 daily` runs
  locally on `@self` and remotely on `host2`.
- Implemented in the target resolver (core), not per-command.

---

## Scheduler research

### systemd timers (Linux)

A `.timer` triggers a `.service` (`Type=oneshot`). systemd waits for
completion.

- **Exit 0** → unit → `inactive`. Silent. Timer schedules next run.
- **Non-zero exit** → unit → `failed`. If `OnFailure=email-notify@%n.service`
  is set, systemd activates that notification unit.
- **`email-notify@.service`** is a template unit. `%i` inside it expands to
  the failed unit name. The script calls `journalctl --user-unit="$1"` to
  get recent logs and pipes them to `sendmail`.
- **Note:** `$SERVICE_RESULT` / `$EXIT_CODE` are NOT passed to `OnFailure=`
  units. The script reads status from `systemctl status` or `journalctl`.
- **Timer continues regardless** — failure does not stop future firings.
- **Logs:** stdout/stderr → journal. `journalctl --user-unit=unit-name`.
- **Persistent=true:** Catches up on missed runs after reboot (servers
  reboot for kernel updates). Single catch-up, not per-missed-interval.
- **Overlap:** Service can only run once. Timer skips if still running.

For generic tasks on Linux, `OnFailure=` + journal is complete. No custom
wrapper needed.

### launchd (macOS)

A `.plist` defines a daemon. `StartCalendarInterval` for scheduling.

- **Exit 0** → done. Silent.
- **Non-zero** → done. **No built-in failure notification. Wrapper needed.**
- **Logs:** `StandardOutPath` / `StandardErrorPath` (absolute paths only).
- **Missed runs:** Fires after wake. Does NOT catch up after full
  power-off (only sleep/wake). For always-on servers this is rarely an
  issue.
- **Overlap:** Automatic. `ThrottleInterval` default 10s.

### cron (fallback — documented only)

- No exit-code tracking. Mails any output to `MAILTO` regardless of
  success/failure. No missed-run recovery. No overlap (`flock` needed).
  Minimal environment.
- Documented as a manual fallback for non-systemd, non-launchd systems.
  Not a primary target.

### Scheduler comparison

| | **systemd timers** | **launchd** | **cron** |
|---|---|---|---|
| Platform | Linux | macOS | Both |
| Missed-run recovery | `Persistent=true` (after reboot) | After wake only | None |
| Failure notification | `OnFailure=` (built-in) | Wrapper needed | Wrapper needed |
| Overlap protection | Automatic | Automatic | Needs `flock` |
| Sudo required? | No (user timers + linger) | Yes (system daemons) | No |
| Runs without login? | Yes (with linger) | Yes (system daemons) | Yes |

---

## sudo requirements

**Linux (systemd):** No sudo needed.
- Unit files → `~/.config/systemd/user/` (user-writable).
- `systemctl --user enable/start` — no sudo.
- `loginctl enable-linger` (for self) — allowed by default polkit
  (`org.freedesktop.login1.set-self-linger`). Survives reboots.
  Ensures user timers run at boot without login.

**macOS (launchd):** System daemons are the primary path for always-on
servers.
- `/Library/LaunchDaemons/`: sudo required to install.
- `UserName` plist key drops privileges to the target user.
- Setup utility must explain the sudo requirement before prompting.

## Runs without login

**Linux:** `loginctl enable-linger` → user service manager starts at boot.
Timers run 24/7 regardless of login. No sudo. This is the default.

**macOS:** System daemons (`/Library/LaunchDaemons/`) run at boot. Require
sudo to install but drop privileges via `UserName`. This is the primary
macOS path for servers.

User agents (`~/Library/LaunchAgents/`) are a secondary option for desktop
Macs where a user is always logged in. No sudo needed but they stop on
logout. There is no macOS equivalent of `enable-linger`.

---

## Notification architecture

```
  Managed host (local timer, single-host):
  ─────────────────────────────────────────
  playbash run @self daily --report
  → playbash wrapper checks exit code AND report
  → sendmail if anything actionable

  Unmanaged hosts (operator fan-out):
  ────────────────────────────────────
  playbash push unmanaged-hosts daily-script --report
  → playbash wrapper checks exit code AND report
  → fan-out report with cross-host aggregation
  → sendmail if anything actionable

  Generic task on systemd (Linux):
  ────────────────────────────────
  OnFailure=email-notify@%n.service
  → reads journal → sendmail
  Nothing custom in the run path.

  Generic task on launchd (macOS) or cron:
  ─────────────────────────────────────────
  notify-on-failure wrapper
  → runs command → checks $? → captures output → sendmail
  Fills the gap the system doesn't cover.
```

### What the scheduler can't know (playbash)

Exit code 0 means "all playbooks completed" but not "nothing needs
attention." Actionable situations that exit 0:

- A host needs a reboot (kernel update, docker upgrade)
- A warning was emitted (held-back package, disk space, etc.)
- An advisory action was reported

Situations that exit non-zero but benefit from structured detail:

- Playbook killed — prompted for sudo (stuck detection)
- Playbook killed — idle too long (stuck detection)
- Playbook step exited non-zero

### Notification trigger rules

Notify when **any** of:
- Any host exited non-zero
- Any `action`-level sidecar event (reboot, needs-sudo, stuck-idle, etc.)
- Any `error`-level sidecar event
- Optionally: `warn`-level events (off by default to avoid noise)

Silent when:
- All hosts succeeded, no actionable/error events (clean run)

### Notification content (playbash)

Answers: "what do I need to do, and on which hosts?"

- Per-host actionable events (reboot, stuck, errors)
- Cross-host aggregation ("reboot needed: host-a, host-b") — needed for
  the unmanaged-hosts fan-out pattern
- Timestamp, playbook name, pass/fail count
- Log paths for failed hosts

---

## Notification delivery

### msmtp (email — the one external dependency)

Standalone SMTP client. No Mutt dependency — the Homebrew description is
misleading. Reads a message on stdin, relays to SMTP server.

| Platform | Install |
|----------|---------|
| Debian/Ubuntu | `apt install msmtp msmtp-mta` |
| Fedora/RHEL | `dnf install msmtp` |
| macOS | `brew install msmtp` |
| Arch | `pacman -S msmtp` |

`msmtp-mta` (Debian) provides `/usr/sbin/sendmail` so systemd's
`OnFailure=` script and wrappers can use `sendmail` generically.

Config: `~/.msmtprc`, mode 0600. Supports TLS, multiple accounts,
`passwordeval` for keyring integration.

### Other channels (document as options, no extra dependencies)

All use `curl` (standard system tool):

| Channel | How | Notes |
|---------|-----|-------|
| ntfy.sh | `curl -d "msg" ntfy.sh/topic` | Self-hosted or free tier |
| Slack/Discord | `curl -X POST -d '{"text":"msg"}'` | Needs webhook URL |
| Pushover | `curl --form-string "token=…"` | Mobile push, needs API key |
| Healthchecks.io | Ping on success; silence = failure | Dead-man's switch |

### msmtp is a prerequisite

The setup utility (`setup-periodic`) checks for `sendmail` in PATH before
creating any scheduler config. If missing, it fails with a clear message
explaining how to install msmtp on the current platform. This is
deliberate — setting up a periodic task without working notifications is
a footgun (silent failures go unnoticed).

The wrappers themselves also check at send time and warn to stderr/journal
if `sendmail` disappeared after setup. For remote detection of "msmtp was
removed," Healthchecks.io-style dead-man's switches are the right tool.

---

## Criticism and risks

1. **Three notification paths.** Generic-on-systemd (`OnFailure=`),
   generic-on-launchd (wrapper), playbash (playbash wrapper). Each
   leverages the most appropriate mechanism for its context. The setup
   utility hides the complexity, but there are three things to maintain.

2. **Warning noise.** Sending on every `warn` may be too noisy. Start
   with action+error only; `warn` opt-in.

3. **Notification flooding.** A broken host emails daily. No dedup.
   Acceptable for small fleet. Healthchecks.io is better for persistent
   failure detection.

4. **macOS power-off gap.** launchd catches up after wake but NOT after
   full power-off. For always-on servers this is rarely an issue (they
   sleep, don't power off). Document it.

5. **`chezmoi update` in unattended mode.** Can hit merge conflicts. Stuck
   detection catches hangs. Failed chezmoi update aborts playbook
   (`set -euo pipefail`). Probably correct.

6. **msmtp removed after setup.** The setup utility gates on msmtp, but
   if it's uninstalled later, wrappers warn to journal but notifications
   go silent. Healthchecks.io ping-on-success is the real solution.

7. **macOS fleet setup via `playbash exec`.** `setup-periodic` on macOS
   needs sudo internally for `launchctl load`. When invoked via
   `playbash exec --sudo`, the injected password may not propagate to
   nested sudo calls. Needs testing. If gnarly, document manual SSH setup
   for macOS hosts as the recommended path.

8. **Unmanaged hosts depend on operator uptime.** The operator fan-out
   pattern (`playbash push unmanaged-hosts ...`) requires the operator
   machine to be up at run time. Acceptable for a small number of
   unmanaged hosts.

---

## Schedule syntax

The original `setup-periodic` interface used `daily` and `weekly` as
mandatory schedule commands with hardcoded day mappings (Mon-Sat and Sun).
This was too rigid — it couldn't express intervals like "every 4 hours",
arbitrary day sets like "Mon, Wed, Fri", or day-of-month schedules.

The new interface uses a compact schedule string with two parts: **when**
(required) and **days** (optional, defaults to every day).

### CLI structure

```
setup-periodic <name> <schedule> "command" [options]
setup-periodic --list
setup-periodic --remove <name>
```

The first positional is the task name — used for the service/plist filename
and for `--remove`. The second is the schedule string (quoted if it
contains a day spec). The third is the command to run.

The `--time` option is removed — time is part of the schedule string.
`--email` is retained.

### When (required, first word of schedule)

| Format | Meaning | Examples |
|--------|---------|---------|
| `HH:MM` | Specific time of day | `4:00`, `04:00`, `23:30` |
| `Nh` | Every N hours | `4h`, `12h`, `1h` |
| `Nm` | Every N minutes | `15m`, `30m` |

Leading zero optional: `4:00` = `04:00`.

When no time is given (days-only schedule is not valid — `<when>` is
always required). When an interval is used without days, the default
time of day for alignment is determined by the scheduler: systemd uses
`0/N` (aligned to midnight), launchd enumerates from hour 0.

### Days (optional, second word of schedule)

Defaults to every day when omitted.

**Day names** — canonical 2-character, lowercase:

| `mo` | `tu` | `we` | `th` | `fr` | `sa` | `su` |
|------|------|------|------|------|------|------|

3-character aliases accepted: `mon`, `tue`, `wed`, `thu`, `fri`, `sat`,
`sun`. Canonical output always uses 2-char form.

**Day-of-week combinators:**

| Format | Meaning | Example |
|--------|---------|---------|
| `mo` | Single day | Monday |
| `mo-fr` | Range (inclusive) | Monday through Friday |
| `mo,we,fr` | List | Monday, Wednesday, Friday |
| `mo-we,fr` | Mixed | Mon-Wed and Friday |
| `sa-mo` | Wrap-around range | Sat, Sun, Mon |

Wrap-around ranges are detected when the start day index exceeds the end
day index (sa=6 > mo=1). Expanded as: start through Sunday, then Monday
through end.

**Day-of-month:**

| Format | Meaning |
|--------|---------|
| `1` | 1st of month |
| `15` | 15th of month |
| `1,15` | 1st and 15th |

Numbers 1-31 in the day spec are interpreted as days of month. Context
is unambiguous: day names are always letters, days of month are always
bare numbers.

Day-of-week and day-of-month **can be mixed** (`1,mo-fr`) but the user
should understand the semantics: both schedulers fire independently, so
if the 1st falls on a weekday, the task runs twice. The utility prints
a warning when week and month days are mixed.

**Deferred:** `last` (last day of month). Neither systemd nor launchd
supports this natively — would require a wrapper that checks `date` at
runtime. Not worth the complexity for now.

### Examples

```bash
# Maintenance: Mon-Sat at 04:00
setup-periodic maint "4:00 mo-sa" "playbash run @self daily --report"

# Weekly: Sunday at 04:00
setup-periodic weekly "4:00 su" "playbash run @self weekly --report"

# Backup every 4 hours
setup-periodic backup 4h "/path/to/backup"

# Health check every 15 minutes
setup-periodic health 15m "health-check"

# Report on 1st and 15th at 06:00
setup-periodic report "6:00 1,15" "generate-report"

# Workdays only at 08:30
setup-periodic notify "8:30 mo-fr" "morning-summary"

# Weekend + Wednesday at 04:00
setup-periodic odd "4:00 we,sa-su" "odd-schedule-task"
```

### Backend mapping

**systemd (OnCalendar):**

| Schedule | OnCalendar value |
|----------|-----------------|
| `4:00` | `*-*-* 04:00:00` |
| `4:00 mo-sa` | `Mon..Sat *-*-* 04:00:00` |
| `4:00 su` | `Sun *-*-* 04:00:00` |
| `4h` | `*-*-* 0/4:00:00` |
| `4h mo-fr` | `Mon..Fri *-*-* 0/4:00:00` |
| `15m` | `*-*-* *:0/15:00` |
| `4:00 1,15` | `*-*-01,15 04:00:00` |
| `4:00 mo-fr` + `1` | Two `OnCalendar=` lines (multiple supported) |

**launchd (StartCalendarInterval / StartInterval):**

| Schedule | Mechanism |
|----------|-----------|
| `4:00 mo-sa` | 6 dicts: Weekday 1-6, Hour 4, Minute 0 |
| `4h` | 6 dicts: Hour 0/4/8/12/16/20, Minute 0 |
| `4h mo-fr` | 30 dicts: 5 days x 6 hours |
| `15m` | `StartInterval=900` (not calendar-aligned) |
| `4:00 1` | 1 dict: Day 1, Hour 4, Minute 0 |
| Mixed week+month | Separate dicts for each type |

**Sub-hour intervals with day filter on macOS:** Rejected. Sub-hour
intervals (`Nm` where N < 60) cannot combine with day-of-week on
launchd — `StartInterval` has no day awareness and enumerating
`StartCalendarInterval` dicts is impractical (e.g. `15m mo-fr` = 480
dicts). The utility rejects this combination on macOS with a clear
error. Sub-hour intervals without a day filter use `StartInterval`.
Hourly and above always use `StartCalendarInterval`.

### Naming convention

The task name becomes the unit/plist identifier:

- **systemd:** `periodic-<name>.service` + `periodic-<name>.timer`
- **launchd:** `com.periodic.<name>.plist`

Names should be short, lowercase, alphanumeric with hyphens. The utility
validates the name format.

### Migration from daily/weekly

The old `setup-periodic daily "cmd"` / `setup-periodic weekly "cmd"`
form is replaced by:

```bash
# Old
setup-periodic daily "playbash run @self daily --report"
setup-periodic weekly "playbash run @self weekly --report"

# New
setup-periodic maint "4:00 mo-sa" "playbash run @self daily --report"
setup-periodic weekly "4:00 su" "playbash run @self weekly --report"
```

The `--remove` interface stays the same but uses the explicit name:
`setup-periodic --remove maint`.

---

## Decisions made

- **Schedulers:** systemd (Linux), launchd (macOS), cron (documented
  fallback only).
- **launchd over cron on macOS.** Cron deprecated on macOS.
- **Leverage built-in mechanisms.** systemd `OnFailure=` for generic tasks.
  Custom wrappers only where the system has no equivalent.
- **Target: always-on servers.** Not laptops — no catch-up-on-open.
- **msmtp is the only external dependency.** Justified, opt-in.
- **Sidecar is single source of truth.** Stuck detection must emit events.
- **Only notify on failure/actionable.** Never on clean success.
- **Setup utility, not `run_once_*`.** Manual opt-in. Explains sudo on
  macOS before prompting.
- **macOS: system daemons primary.** `UserName` for privilege drop. User
  agents secondary for always-on desktops.
- **Linux: no sudo.** User timers + self-linger.
- **Language:** Node for playbash changes. Bash for wrappers, setup
  utility. Templates for unit files / plists.
- **`--report` flag** on `playbash run` for notification summary (not a
  separate subcommand). Simpler — one invocation.
- **No special exit code.** Wrapper checks report content to detect
  "succeeded but actionable." Exit 0 stays clean, avoids confusing other
  tooling that treats non-zero as failure.
- **`setup-periodic`** — standalone generic utility. Self-descriptive name.
  Not a playbash subcommand (it handles generic tasks too).
- **msmtp is a prerequisite.** `setup-periodic` checks for `sendmail` and
  fails with install instructions if missing.
- **Schedule syntax:** compact `<when> [<days>]` string. 2-char day names
  (`mo`-`su`), 3-char aliases accepted. Ranges (`mo-fr`), lists
  (`mo,we,fr`), wrap-around ranges (`sa-mo`), day-of-month (`1`, `15`).
  No predefined day groups. Default time 04:00.
- **Sub-hour + day filter on macOS:** rejected — launchd can't do it
  cleanly. Sub-hour without day filter uses `StartInterval`.
- **Mixed week/month days:** allowed but warns. Schedulers fire
  independently (possible double-run on overlap).
- **`last` day of month:** deferred — no native backend support.
- **`@self` pseudo-host.** Resolves to actual hostname for display, implies
  `--self`, works with all subcommands. Implemented in the target resolver.
- **Local timers as primary path.** Each managed host runs
  `playbash run @self daily --report` via its own timer. Self-contained.
- **Operator fan-out for unmanaged hosts.** Timer on operator machine runs
  `playbash push unmanaged-hosts daily-script --report`. Fan-out report
  with cross-host aggregation needed for this.
- **Always use `playbash run` form for scheduled tasks.** Direct
  `playbash-daily` execution is possible but lacks reporting. Document
  the trade-off in the wiki.
