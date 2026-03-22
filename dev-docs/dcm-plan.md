# dcm — Docker Compose Manager

Implementation plan for `dcm`, a CLI utility that manages Docker Compose setups.

## Design decisions

| Decision | Choice |
|---|---|
| Script name | `dcm` (Docker Compose Manage) |
| Default directory | Current directory (`.`) |
| Multi-setup | `--all` flag targets every setup under `~/servers` |
| Image pruning | Prune by default; `--no-prune` to skip |
| Force recreate | Opt-in with `--force` |
| Argument parsing | `options.bash` (consistent with `imop`, `upd`, `jot`, etc.) |
| Privilege escalation | Plain `sudo` (aliased to `doas` when available via `main.sh`) |

## Commands

```
dcm update [dir]     # Pull images, recreate changed containers, prune (default command)
dcm down [dir]       # Compose down
dcm stop [dir]       # Compose stop (pause without removing)
dcm start [dir]      # Compose start (resume stopped services)
dcm restart [dir]    # Compose restart
dcm status [dir]     # Compose ps (show running services)
```

If no command is given, `update` is the default (the "happy path").

The optional `[dir]` defaults to `.` (current directory). It must contain a compose file
(`compose.yaml`, `compose.yml`, `docker-compose.yaml`, or `docker-compose.yml`).

## Global options

| Option | Description |
|---|---|
| `--all` | Operate on every setup under `~/servers` |
| `--force` | Pass `--force-recreate` to `docker compose up` |
| `--no-prune` | Skip `docker image prune -af` after update |
| `-n, --dry-run` | Show commands without running |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

## AppArmor recovery

Docker on Ubuntu occasionally fails with AppArmor-related errors when starting, stopping, or
killing containers. The typical stderr signatures are:

- `permission denied`
- `cannot kill container`
- `cannot stop container`

### Detection and retry strategy

1. Capture stderr and exit code from `docker compose` commands.
2. If exit code is 0, proceed normally.
3. If exit code != 0:
   a. If stderr matches an AppArmor pattern (`permission denied` combined with container ops):
      - Log a warning: "AppArmor conflict detected, clearing stale profiles..."
      - Run `sudo aa-remove-unknown`.
      - Retry the failed `docker compose` command once.
      - If the retry also fails, print stderr and exit with the error code.
   b. Otherwise, print the captured stderr and exit with the error code.
      The user must always see what went wrong, even for unexpected failures.

Since `main.sh` aliases `sudo` to `doas` when available, scripts just use plain `sudo`.
For non-interactive use, configure passwordless access in `/etc/doas.conf`:

```
permit nopass <user> cmd aa-remove-unknown
```

### Scope

AppArmor recovery applies only on Linux. The detection function should be a no-op on macOS
(where AppArmor does not exist).

## Implementation phases

### Phase 1: Core single-setup commands

- Bash script at `private_dot_local/bin/executable_dcm`.
- Boilerplate: `options.bash` integration, tool detection (`docker`, `docker compose`).
- `update` command: `docker compose pull` → `docker compose up -d` → `docker image prune -af`.
- `down`, `stop`, `start`, `restart`, `status` commands.
- `--force` and `--no-prune` flags.
- `--dry-run` support.
- Default command inference: no args or bare `[dir]` → `update`.
- Validate that target directory contains a compose file.

### Phase 2: AppArmor recovery

- `run_compose()` wrapper that captures stderr and detects AppArmor errors.
- Automatic `sudo aa-remove-unknown` + retry.
- Linux-only guard (`uname -s`).

### Phase 3: Multi-setup (`--all`)

- Discover setups: find directories under `~/servers` containing a compose file
  (`compose.yaml`, `compose.yml`, `docker-compose.yaml`, or `docker-compose.yml`).
- Iterate and run the requested command in each.
- Summary report at the end (which setups succeeded/failed).
- The base directory (`~/servers`) should be a variable at the top of the script for easy
  customization. Future: make it configurable via env var or config file.

## Command flow: `dcm update`

```
dcm update [dir] [--force] [--no-prune] [--all] [-n]

1. Resolve target dir(s):
   - If --all: discover all compose dirs under ~/servers
   - Else: use [dir] or .
2. For each target dir:
   a. Validate compose file exists
   b. run_compose pull
   c. run_compose up -d [--force-recreate]
   d. If not --no-prune: docker image prune -af
3. Report results
```

Where `run_compose` is:

```
run_compose <args...>:
  1. Run: docker compose <args>; capture stderr and exit code
  2. If exit code == 0: return success
  3. If exit code != 0:
     a. If Linux AND stderr matches AppArmor pattern:
        - Warn: "AppArmor conflict detected"
        - Run: sudo aa-remove-unknown
        - Retry: docker compose <args>
        - If retry fails: print stderr, return error
     b. Else: print stderr, return error
```

## Output style

Consistent with other utilities (`imop`, `upd`, `ollama-sync`):

- `ansi::out` / `ansi::err` for terminal-aware colored output.
- `echoRun` / `echoRunBold` for showing commands before execution.
- Color scheme: `$FG_CYAN` for info, `$BOLD$FG_YELLOW` for warnings,
  `$BOLD$BRIGHT_WHITE$BG_RED` for errors, `$BOLD$FG_GREEN` for success.

## Future directions

### Near-term

- **Logging**: Write a timestamped log to `~/.local/share/dcm/update.log` when run
  from cron. Detect non-interactive mode via `[[ -t 1 ]]` and auto-enable logging.
- **Change detection**: After `docker compose pull`, parse output for "Downloaded newer image"
  to report which services actually updated. This is useful for notifications.

### Medium-term

- **Scheduled updates**: `systemd` timer or `cron` job that runs `dcm update --all`.
  Provide a `dcm install-timer` subcommand that creates the systemd unit files.
- **Notifications**: When run non-interactively, send a summary of updated services via:
  - Log file (simplest, always available)
  - Email (`sendmail` / `msmtp`)
  - Push notification (`ntfy.sh`, `gotify`, or similar self-hosted service)
  - The notification backend should be pluggable — start with log file, add others as needed.

### Long-term

- **Remote operation**: Run commands on remote servers via SSH.
  Could be as simple as `dcm update --host server1` wrapping `ssh server1 dcm update --all`,
  or a more structured approach with `ansible` playbooks.
  The current single-machine design doesn't preclude this — the script is self-contained
  and can be installed on remote machines via chezmoi.
- **Health checks**: After update, verify services are healthy via `docker compose ps`
  and report any that failed to start.
- **Rollback**: Before updating, record current image digests. If the new version fails
  health checks, offer to roll back to the previous digest.
- **Config management**: Track which setups exist, their update schedules, and notification
  preferences in a simple config file (`~/.config/dcm/config`).
