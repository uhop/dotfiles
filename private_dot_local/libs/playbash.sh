# playbash.sh — helper library sourced by playbash playbooks.
#
# Usage from a playbook:
#
#     #!/usr/bin/env bash
#     source "${PLAYBASH_LIBS:-$HOME/.local/libs}/playbash.sh"
#     playbash_step "package-upgrade"
#     playbash_warn "package X held back" --target apt
#     playbash_reboot "kernel updated to 6.17.2"
#
# When $PLAYBASH_REPORT is set (the runner sets it), helpers append a JSON
# object per line to that file. When unset (manual debugging), helpers
# pretty-print to stderr instead. Either way, helpers never fail the
# playbook — they swallow their own errors.
#
# Note: this library does not use flock. Playbooks are single-process; if
# one ever forks helper calls into background jobs with `&`, it must
# serialize them itself.
#
# Note: this library deliberately does NOT depend on options.bash. The
# pretty-print path only runs when $PLAYBASH_REPORT is unset, which is
# the manual-debugging case where stderr is always a tty. options.bash's
# main benefit (auto-strip when output is not a tty) does not apply.
# Playbooks that source bootstrap.sh for their own needs can use
# options.bash and this library side by side.

: "${PLAYBASH_LIBS:=$HOME/.local/libs}"
: "${PLAYBASH_STEP:=}"

_playbash_report_broken=

if [ -t 2 ]; then
  _playbash_c_reset=$'\033[0m'
  _playbash_c_dim=$'\033[2m'
  _playbash_c_info=$'\033[36m'
  _playbash_c_warn=$'\033[33m'
  _playbash_c_error=$'\033[31m'
  _playbash_c_action=$'\033[35m'
else
  _playbash_c_reset=
  _playbash_c_dim=
  _playbash_c_info=
  _playbash_c_warn=
  _playbash_c_error=
  _playbash_c_action=
fi

# JSON-escape a string. Handles backslash, quote, and the common control chars.
_playbash_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Pretty-print fallback when there is no sidecar to write to.
_playbash_pretty() {
  local level=$1 msg=$2 kind=$3 target=$4
  local color label
  case $level in
    info)   color=$_playbash_c_info;   label="INFO  " ;;
    warn)   color=$_playbash_c_warn;   label="WARN  " ;;
    error)  color=$_playbash_c_error;  label="ERROR " ;;
    action) color=$_playbash_c_action; label="ACTION" ;;
    *)      color=;                    label=$level ;;
  esac
  local prefix="${color}${label}${_playbash_c_reset}"
  [ -n "$kind" ]          && prefix+=" ${color}${kind}${_playbash_c_reset}"
  [ -n "$PLAYBASH_STEP" ] && prefix+=" ${_playbash_c_dim}[${PLAYBASH_STEP}]${_playbash_c_reset}"
  local suffix=
  [ -n "$target" ] && suffix=" ${_playbash_c_dim}(${target})${_playbash_c_reset}"
  printf '%s %s%s\n' "$prefix" "$msg" "$suffix" >&2
}

# Internal: emit one event. Args: level, msg, then optional --target X --data JSON --kind K.
#
# Contract: --target and --kind are plain strings (escaped as JSON strings on
# emission). --data is a pre-formed JSON value — a number, a JSON object, a
# JSON array, etc. — and is inserted verbatim into the sidecar line. Callers
# passing --data are responsible for producing valid JSON; the helper does
# NOT escape it. No built-in playbash_* function exposes --data today, so
# this is a latent extension point for custom emitters.
_playbash_emit() {
  local level=$1 msg=$2
  shift 2
  local target= data= kind=
  while [ $# -gt 0 ]; do
    case $1 in
      --target) target=$2; shift 2 ;;
      --data)   data=$2;   shift 2 ;;
      --kind)   kind=$2;   shift 2 ;;
      *)        shift ;;
    esac
  done

  if [ -n "${PLAYBASH_REPORT:-}" ] && [ -z "$_playbash_report_broken" ]; then
    local ts
    ts=$(date -Iseconds 2>/dev/null || date)
    local line='{"ts":"'$(_playbash_json_escape "$ts")'","level":"'$level'","msg":"'$(_playbash_json_escape "$msg")'"'
    [ -n "$kind" ]          && line+=',"kind":"'$(_playbash_json_escape "$kind")'"'
    [ -n "$target" ]        && line+=',"target":"'$(_playbash_json_escape "$target")'"'
    [ -n "$PLAYBASH_STEP" ] && line+=',"step":"'$(_playbash_json_escape "$PLAYBASH_STEP")'"'
    [ -n "$data" ]          && line+=',"data":'"$data"
    line+='}'
    if ! printf '%s\n' "$line" >> "$PLAYBASH_REPORT" 2>/dev/null; then
      _playbash_report_broken=1
      printf '%splaybash:%s report file %s is unwritable; falling back to stderr\n' \
        "$_playbash_c_warn" "$_playbash_c_reset" "$PLAYBASH_REPORT" >&2
      _playbash_pretty "$level" "$msg" "$kind" "$target"
    fi
  else
    _playbash_pretty "$level" "$msg" "$kind" "$target"
  fi
}

# Public API.

playbash_info()  { _playbash_emit info  "$@" || true; }
playbash_warn()  { _playbash_emit warn  "$@" || true; }
playbash_error() { _playbash_emit error "$@" || true; }

playbash_action() {
  local kind=$1; shift
  local msg=$1;  shift
  _playbash_emit action "$msg" --kind "$kind" "$@" || true
}

playbash_reboot() {
  local msg=$1; shift
  playbash_action reboot "$msg" "$@"
}

playbash_step() {
  PLAYBASH_STEP=$1
  export PLAYBASH_STEP
}
