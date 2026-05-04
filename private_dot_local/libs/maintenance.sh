# maintenance.sh — reporting helpers shared between maintenance scripts
# (`upd`, `cln`, ...).
#
# Each `report_*` helper does two things:
#   1. Prints a colored, human-readable message via options.bash, exactly
#      like the inline `ansi::out` calls these scripts used to make.
#   2. When $PLAYBASH_REPORT is set (the playbash runner sets it for any
#      run that flows through it), appends a JSON-lines event to that
#      sidecar file matching the schema understood by the runner's
#      summary renderer (see ../share/playbash/sidecar.js).
#
# When $PLAYBASH_REPORT is unset (manual run from a shell), the helpers
# just print and skip the sidecar write.
#
# This file does NOT depend on playbash.sh — it implements its own
# minimal sidecar writer inline. Maintenance scripts and the playbash
# runner are conceptually separate; we don't want a transitive dependency
# from upd/cln onto the playbash helper library.
#
# Sources options.bash via the bootstrap when needed; assumes WARN, BOLD,
# RESET_ALL, ITALIC, BLINK, REVERSE etc. are already in scope (callers
# source bootstrap.sh before this file).

# --- Reporting helpers ---

# Internal: write one JSON-lines event to $PLAYBASH_REPORT, if set.
# Args: level msg [kind] [target]
_maintenance_emit_event() {
  [ -n "${PLAYBASH_REPORT:-}" ] || return 0
  local level=$1 msg=$2 kind=${3:-} target=${4:-}
  local ts; ts=$(date -Iseconds 2>/dev/null || date)
  # JSON escape: backslash, quote, common control chars.
  local m=$msg
  m=${m//\\/\\\\}
  m=${m//\"/\\\"}
  m=${m//$'\b'/\\b}
  m=${m//$'\f'/\\f}
  m=${m//$'\n'/\\n}
  m=${m//$'\r'/\\r}
  m=${m//$'\t'/\\t}
  local line='{"ts":"'$ts'","level":"'$level'","msg":"'$m'"'
  if [ -n "$kind" ]; then
    local k=$kind
    k=${k//\\/\\\\}
    k=${k//\"/\\\"}
    line+=',"kind":"'$k'"'
  fi
  if [ -n "$target" ]; then
    local t=$target
    t=${t//\\/\\\\}
    t=${t//\"/\\\"}
    line+=',"target":"'$t'"'
  fi
  line+='}'
  printf '%s\n' "$line" >> "$PLAYBASH_REPORT" 2>/dev/null || true
}

# report_reboot REASON
#   Standardized "reboot is required" warning. Always prints the colored
#   message used by upd/cln historically. Adds the reason in parentheses.
#   When $PLAYBASH_REPORT is set, also writes an action/reboot event.
report_reboot() {
  local reason=${1:-system updates require reboot}
  ansi::out "${WARN}WARNING: reboot is ${BLINK}${REVERSE}required${RESET_ALL}${WARN} (${reason}). To reboot run: ${ITALIC}reboot${RESET_ALL}${WARN} or ${ITALIC}sudo shutdown -r now${RESET_ALL}"
  _maintenance_emit_event action "$reason" reboot ""
}

# maintenance::reboot_reminder
#   Compact end-of-script reminder. No-op if no reboot is pending.
#   Intended for the very end of upd/cln so the warning is the last
#   thing the operator sees, not buried mid-output where the louder
#   `report_reboot` fired earlier from check_apt_since. Cross-platform
#   via the `restart-pending` helper.
maintenance::reboot_reminder() {
  local reason
  reason=$(restart-pending 2>/dev/null) || return 0
  [ -n "$reason" ] || return 0
  ansi::out "${WARN}↻ Reboot required: ${reason} (run ${ITALIC}sudo reboot${RESET_ALL}${WARN})${RESET_ALL}"
}

# macOS restart marker. Written by upd's darwin block when softwareupdate
# flags a restart-required update. Stamped with the current boot time so
# a reboot implicitly invalidates it; `restart-pending` clears the marker
# when boot time has moved on.
MACOS_RESTART_MARKER=${MACOS_RESTART_MARKER:-${XDG_CACHE_HOME:-$HOME/.cache}/playbash/macos-restart-pending}

maintenance::mark_macos_restart() {
  mkdir -p "$(dirname "$MACOS_RESTART_MARKER")"
  sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/' > "$MACOS_RESTART_MARKER"
}

# report_warn MSG [--target X]
report_warn() {
  local msg=$1; shift
  local target=
  while [ $# -gt 0 ]; do
    case $1 in
      --target) target=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$target" ]; then
    ansi::out "${WARN}WARNING: ${msg} (${target})${RESET_ALL}"
  else
    ansi::out "${WARN}WARNING: ${msg}${RESET_ALL}"
  fi
  _maintenance_emit_event warn "$msg" "" "$target"
}

# report_action KIND MSG [--target X]
#   Generic structured action other than reboot.
report_action() {
  local kind=$1; shift
  local msg=$1; shift
  local target=
  while [ $# -gt 0 ]; do
    case $1 in
      --target) target=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  ansi::out "${WARN}ACTION (${kind}): ${msg}${RESET_ALL}"
  _maintenance_emit_event action "$msg" "$kind" "$target"
}

# --- AppArmor marker (interrupted-cleanup recovery) ---
#
# When apt upgrades the apparmor package, docker may break until
# `aa-remove-unknown` runs. We do that immediately. But if the user aborts
# during the sudo prompt (no doas, no whitelist) the cleanup never
# happens, and a subsequent `upd` run wouldn't detect anything (apt has
# nothing new to do). The marker file persists between runs and is
# checked at startup of every maintenance script.
#
# Path is in ~/.cache so it's user-writable (no sudo needed to create).
# It's removed only after a successful `aa-remove-unknown`.

APPARMOR_MARKER=${APPARMOR_MARKER:-${XDG_CACHE_HOME:-$HOME/.cache}/playbash/needs-aa-cleanup}

maintenance::mark_apparmor_dirty() {
  mkdir -p "$(dirname "$APPARMOR_MARKER")"
  : > "$APPARMOR_MARKER"
}

maintenance::cleanup_apparmor_if_marked() {
  [ -e "$APPARMOR_MARKER" ] || return 0
  command -v aa-remove-unknown >/dev/null 2>&1 || return 0
  ansi::out "${WARN}AppArmor cleanup needed (from a previous upgrade); running ${ITALIC}aa-remove-unknown${RESET_ALL}${WARN} to keep docker working. May require sudo password.${RESET_ALL}"
  if sudo aa-remove-unknown >/dev/null 2>&1; then
    rm -f "$APPARMOR_MARKER"
    report_warn "ran aa-remove-unknown to clean up after apparmor upgrade" --target apparmor
  fi
}

# --- apt history scanning ---
#
# Maintenance scripts (`upd`, `cln`) snapshot the byte position of
# /var/log/apt/history.log before doing apt operations. After the apt
# step, they call `maintenance::check_apt_since` with that snapshot.
# The function diffs the new tail of history.log, scans the Upgrade:
# lines for known package names, and reacts:
#
#   - docker-related (docker-ce, containerd, docker-buildx-plugin,
#     docker-compose-plugin) → `report_reboot "docker upgraded; restart
#     recommended"` (auto-restart is a future enhancement).
#   - apparmor / apparmor-utils → mark dirty + run cleanup.
#   - /run/reboot-required exists (any cause, kernel etc.) → report_reboot
#     with the package list as the reason if available.
#
# Linux-only. The functions are no-ops on Mac (no apt, no /var/log/apt).

maintenance::snapshot_apt() {
  if [ -f /var/log/apt/history.log ]; then
    wc -c < /var/log/apt/history.log
  else
    echo 0
  fi
}

# Reads the new tail of history.log added since SNAPSHOT and prints it
# on stdout. Returns 0 even if there's nothing new.
_maintenance_apt_diff() {
  local snapshot=$1
  [ -f /var/log/apt/history.log ] || return 0
  local current; current=$(wc -c < /var/log/apt/history.log)
  if [ "$current" -le "$snapshot" ]; then return 0; fi
  tail -c +"$((snapshot + 1))" /var/log/apt/history.log
}

# maintenance::check_apt_since SNAPSHOT [restart_docker]
#
# When restart_docker is 1, a detected docker-related upgrade triggers
# `maintenance::restart_docker_services` (which falls back to
# `report_reboot` if the restart fails). When 0 or unset (default), the
# upgrade is just reported via `report_reboot`. AppArmor and kernel
# reboot detection are unaffected by this flag.
maintenance::check_apt_since() {
  local snapshot=${1:-0}
  local restart_docker=${2:-0}
  local diff; diff=$(_maintenance_apt_diff "$snapshot")

  # Docker-related upgrades. The Upgrade: line lists packages with
  # version transitions; we match the package name followed by `:`.
  if printf '%s' "$diff" | grep -qE 'Upgrade:.*\b(docker-ce|containerd|docker-buildx-plugin|docker-compose-plugin):'; then
    if [ "$restart_docker" = "1" ]; then
      maintenance::restart_docker_services
    else
      report_reboot "docker upgraded; restart recommended (a reboot is the safest option)"
    fi
  fi

  # AppArmor upgrade → mark dirty, then run cleanup immediately.
  if printf '%s' "$diff" | grep -qE 'Upgrade:.*\b(apparmor|apparmor-utils):'; then
    maintenance::mark_apparmor_dirty
    maintenance::cleanup_apparmor_if_marked
  fi

  # Generic kernel-style reboot signal (apt creates this file when any
  # package wants a reboot, kernels included). The pkgs file lists what
  # caused it; use it as the reason if available.
  if [ -e /run/reboot-required ]; then
    local reason
    reason=$(head -1 /run/reboot-required.pkgs 2>/dev/null || true)
    if [ -z "$reason" ]; then
      reason="system updates require reboot"
    else
      reason="${reason} updated"
    fi
    report_reboot "$reason"
  fi
}

# Try to recover from a docker-ce upgrade by restarting the service
# stack. Falls back to `report_reboot` if either restart fails so the
# user still sees a warning.
#
# Order matters: containerd first (the runtime), then docker (the daemon
# above it). Docker's systemd unit has `Requires=containerd.service`, so
# restarting containerd first means docker comes up against a fresh
# runtime instead of reconnecting to a possibly-stale one.
#
# Both commands are individually whitelisted in the doas config so they
# don't prompt for a password on hosts where doas is configured.
maintenance::restart_docker_services() {
  ansi::out "${WARN}Docker was upgraded — restarting containerd and docker. May require sudo password.${RESET_ALL}"
  if echoRun --bold sudo systemctl restart containerd && echoRun --bold sudo systemctl restart docker; then
    report_warn "docker daemon restarted after docker-ce upgrade" --target docker
  else
    ansi::out "${WARN}Service restart failed; falling back to reboot recommendation.${RESET_ALL}"
    report_reboot "docker upgraded and service restart failed; reboot recommended"
  fi
}
