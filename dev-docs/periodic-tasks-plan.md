# Periodic tasks plan

## Goal

Automate daily and weekly maintenance on every managed machine with failure
notifications. Two operating modes:

1. **Local cron** — each host runs its own `playbash-daily` / `playbash-weekly`.
2. **Central playbash** — one operator machine runs `playbash run all daily` /
   `playbash run all weekly` to fan out across the fleet.

Both modes should be documented. Local cron is the primary target — it is
simpler, doesn't depend on operator uptime, and works for standalone machines.

## Schedule

- **Daily (Mon–Sat):** `playbash-daily` (chezmoi update → dcms → upd -ry)
- **Weekly (Sunday):** `playbash-weekly` (chezmoi update → dcms → upd -cry)
- Daily does NOT run on Sunday — the weekly replaces it.

## Scheduler: systemd timers vs cron

### systemd timers (recommended)

- Built-in logging via journal (`journalctl -u playbash-daily`)
- `Persistent=true` catches up on missed runs (laptop was asleep)
- `OnFailure=` can trigger a notification unit
- No extra daemon — systemd is already running

### cron (fallback)

- Simpler one-liner setup
- Works on non-systemd systems (macOS, older Linux)
- No built-in missed-run recovery
- Notification requires a wrapper script

### Decision

Document both. Provide systemd timer units as the primary approach (chezmoi-managed
via `run_onchange_*` or template files). Document cron as a manual alternative for
macOS and non-systemd hosts.

## Failure notifications

### Email (primary)

Use `msmtp` as a lightweight sendmail replacement. It is a single binary, supports
TLS, and can relay through Gmail/Fastmail/any SMTP provider.

Setup:
1. Install `msmtp` + `msmtp-mta` (provides `/usr/sbin/sendmail` symlink)
2. Configure `~/.msmtprc` with SMTP credentials
3. For systemd: an `OnFailure=email-notify@%n.service` unit that sends a
   one-line failure email using `sendmail`
4. For cron: wrap the command in a script that captures exit code and mails
   on failure (cron's built-in MAILTO only works if an MTA is configured)

### Other channels (document as options)

| Channel | Complexity | Notes |
|---------|------------|-------|
| **ntfy.sh** | Low | Self-hosted or free tier. `curl -d "msg" ntfy.sh/topic`. No auth needed for public topics. |
| **Slack/Discord webhook** | Low | Single `curl` call. Needs a webhook URL. |
| **Pushover** | Low | Mobile push notifications. Needs API key. |
| **Healthchecks.io** | Low | Ping-based dead-man's switch. Good for detecting missed runs. Free tier available. |

### Missed-run detection

systemd's `Persistent=true` handles catch-up. For additional monitoring,
healthchecks.io-style "dead man's switch" pings can detect hosts that went
silent. Document as an optional add-on.

## Implementation

### Phase 1: wiki documentation

Create `Workflows-maintenance.md` section (or a separate wiki page) covering:
- How to set up systemd timers manually
- How to set up cron manually
- How to configure msmtp for failure emails
- Other notification channels as options

### Phase 2: chezmoi-managed timer units (optional)

If the manual setup proves too tedious, create:
- `private_dot_config/systemd/user/playbash-daily.service.tmpl`
- `private_dot_config/systemd/user/playbash-daily.timer.tmpl`
- `private_dot_config/systemd/user/playbash-weekly.service.tmpl`
- `private_dot_config/systemd/user/playbash-weekly.timer.tmpl`
- `private_dot_config/systemd/user/email-notify@.service.tmpl`
- A `run_onchange_*` script to enable the timers

User-level systemd units (`--user`) avoid needing root but require
`loginctl enable-linger` for the user. System-level units are an alternative
if the playbooks need to run regardless of login state.

### Phase 3: msmtp setup helper (optional)

A guided setup script or `run_once_*` that:
1. Installs msmtp
2. Prompts for SMTP server, port, user, password
3. Writes `~/.msmtprc` with correct permissions (0600)
4. Sends a test email

## Open questions

1. **User-level vs system-level timers?** User-level is safer (no root) but
   requires linger. System-level is simpler for servers that are always on.
   → Probably document both, recommend user-level for desktops, system-level
   for headless servers.

2. **SMTP credentials storage?** `~/.msmtprc` with mode 0600 is standard.
   Could also use `secret-tool` / keyring integration, but adds complexity.
   → Start with file-based, document keyring as option.

3. **Should msmtp be in the Brewfile/package list?** It's only needed on
   machines that want email notifications.
   → Keep it opt-in, document `apt install msmtp msmtp-mta` in the wiki.
