# test_ensure.sh — pkg_ensure orchestrator (§3.6.3 batched install).

load_lib

# Shared fixture: replace the default apt/brew registrations with clean
# templates so test stubs don't need to reason about \${Status}-style
# quoting. These stand in for any two managers.
setup_ensure_host() {
  detect::reset
  detect::mgr_register apt \
    'apt-cache show {pkg}' \
    'apt-has {pkg}' \
    '' \
    'apt-install {pkgs}'
  detect::mgr_register brew \
    'brew info --formula {pkg}' \
    'brew-has {pkg}' \
    '' \
    'brew-install {pkgs}'
  detect::_which() { case "$1" in apt-get|brew) return 0 ;; *) return 1 ;; esac; }
  unset DETECT_ALLOW_SNAP DETECT_OPT_OUT
  # Reset test-state assoc arrays so previous cases don't leak.
  avail_ok=()
  has_ok=()
  install_ok=()
  install_ok[apt]=1
  install_ok[brew]=1
  # Reset recorder globals used by test stubs.
  commands_run=()
  install_commands=()
}

# Helper stub: captures install commands, answers probe commands by lookup.
# Tests populate `avail_ok`, `has_ok`, `install_ok` maps before calling
# pkg_ensure.
#   avail_ok[foo]=1   → apt-cache show foo returns 0
#   has_ok[foo]=1     → apt-has foo returns 0
#   install_ok[apt]=1 → apt-install succeeds (default)
declare -A avail_ok has_ok install_ok
install_ok[apt]=1
install_ok[brew]=1

setup_stubs() {
  detect::_run() {
    if [[ $1 == bash && $2 == -c ]]; then
      commands_run+=("$3")
      local c="$3"
      # Probe paths — check avail / has maps.
      case "$c" in
        'apt-cache show '*|'brew info --formula '*)
          local pkg=${c##* }
          [[ ${avail_ok[$pkg]:-0} == 1 ]] && return 0 || return 1 ;;
        'apt-has '*|'brew-has '*)
          local pkg=${c##* }
          [[ ${has_ok[$pkg]:-0} == 1 ]] && return 0 || return 1 ;;
        'apt-install '*)
          install_commands+=("$c")
          [[ ${install_ok[apt]:-1} == 1 ]] && return 0 || return 1 ;;
        'brew-install '*)
          install_commands+=("$c")
          [[ ${install_ok[brew]:-1} == 1 ]] && return 0 || return 1 ;;
      esac
    fi
    return 1
  }
}

# ---------- Empty args → no-op success ----------

setup_ensure_host
setup_stubs
set +e
detect::pkg_ensure 2>/dev/null
rc=$?
set -e
assert::eq "$rc" "0" "pkg_ensure: empty args → 0"
assert::eq "${#install_commands[@]}" "0" "pkg_ensure: empty args → no install commands"

# ---------- Single capability, not installed → runs install ----------

setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='
apt:nano
'
avail_ok[nano]=1
unset 'has_ok[nano]'
detect::pkg_ensure editor 2>/dev/null
assert::eq "${#install_commands[@]}" "1" "pkg_ensure: single → one install call"
assert::eq "${install_commands[0]}"   "apt-install nano"  "pkg_ensure: batched cmd string"

# ---------- Single capability, already installed → skip ----------

setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='
apt:nano
'
avail_ok[nano]=1
has_ok[nano]=1
stderr_out=$(detect::pkg_ensure editor 2>&1 >/dev/null)
assert::eq "${#install_commands[@]}" "0" "pkg_ensure: already installed → no install"
case "$stderr_out" in
  *"[skip]"*"editor"*"apt/nano"*"already installed"*)
    printf '  ok   pkg_ensure: prints skip line with (mgr/name)\n' ;;
  *)
    printf '  FAIL pkg_ensure: skip line missing\n       got: %s\n' "$stderr_out"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- Multiple capabilities same manager → single batch ----------

setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='apt:nano'
__DETECT_CANDIDATES[vcs]='apt:git'
__DETECT_CANDIDATES[json]='apt:jq'
avail_ok[nano]=1; avail_ok[git]=1; avail_ok[jq]=1
detect::pkg_ensure editor vcs json 2>/dev/null
assert::eq "${#install_commands[@]}" "1" "pkg_ensure: same-mgr → single batched call"
case "${install_commands[0]}" in
  'apt-install nano git jq'|'apt-install '*'nano'*'git'*'jq'*)
    printf '  ok   pkg_ensure: batch includes all pkgs in order\n' ;;
  *)
    printf '  FAIL pkg_ensure: batch contents unexpected: %q\n' "${install_commands[0]}"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- Multiple capabilities different managers → one install each ----------

setup_ensure_host
setup_stubs
# DETECT_OPT_OUT won't help split — need each capability resolved to a
# different manager. Use two distinct capabilities targeting different mgrs.
__DETECT_CANDIDATES[editor]='apt:nano'
__DETECT_CANDIDATES[brewed]='brew:only-brew-pkg'
avail_ok[nano]=1
avail_ok[only-brew-pkg]=1
detect::pkg_ensure editor brewed 2>/dev/null
assert::eq "${#install_commands[@]}" "2" "pkg_ensure: distinct-mgrs → 2 install calls"

# ---------- Unresolved capability, non-strict → warn + continue ----------

# Warning reaches stderr (via subshell capture).
setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='apt:nano'
__DETECT_CANDIDATES[nope]='dnf:only-dnf-pkg'  # dnf not active on this host
avail_ok[nano]=1
stderr_out=$(detect::pkg_ensure editor nope 2>&1 >/dev/null)
case "$stderr_out" in
  *"no candidate resolved for 'nope'"*)
    printf '  ok   pkg_ensure: unresolved → warn\n' ;;
  *)
    printf '  FAIL pkg_ensure: expected "no candidate resolved" warning\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# Install_commands tracked in parent shell — need a fresh run without `$(...)`.
setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='apt:nano'
__DETECT_CANDIDATES[nope]='dnf:only-dnf-pkg'
avail_ok[nano]=1
detect::pkg_ensure editor nope 2>/dev/null
assert::eq "${#install_commands[@]}" "1" "pkg_ensure: unresolved doesn't block rest"

# ---------- Unresolved + --strict → return 2 ----------

setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[nope]='dnf:only-dnf-pkg'
set +e
detect::pkg_ensure --strict nope 2>/dev/null
rc=$?
set -e
assert::eq "$rc" "2" "pkg_ensure: --strict + unresolved → rc 2"

# ---------- --dry-run → no installs, prints plan ----------

setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='apt:nano'
avail_ok[nano]=1
stderr_out=$(detect::pkg_ensure --dry-run editor 2>&1 >/dev/null)
assert::eq "${#install_commands[@]}" "0" "pkg_ensure: --dry-run → no install executed"
case "$stderr_out" in
  *"[dry-run]"*"apt-install nano"*)
    printf '  ok   pkg_ensure: --dry-run prints plan\n' ;;
  *)
    printf '  FAIL pkg_ensure: --dry-run plan missing\n       got: %s\n' "$stderr_out"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- Install failure → rc 1 ----------

setup_ensure_host
setup_stubs
__DETECT_CANDIDATES[editor]='apt:nano'
avail_ok[nano]=1
install_ok[apt]=0
set +e
detect::pkg_ensure editor 2>/dev/null
rc=$?
set -e
assert::eq "$rc" "1" "pkg_ensure: install failure → rc 1"
install_ok[apt]=1

# ---------- Unknown flag → rc 64 ----------

setup_ensure_host
setup_stubs
set +e
detect::pkg_ensure --frobnicate editor 2>/dev/null
rc=$?
set -e
assert::eq "$rc" "64" "pkg_ensure: unknown flag → rc 64"
