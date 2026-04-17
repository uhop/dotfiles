# test_resolver.sh — detect::pkg_resolve + active_managers (§3.4 + §3.7).
#
# Populates __DETECT_CANDIDATES directly rather than sourcing
# detect-packages.sh so assertions are independent of whatever capability
# entries the data file happens to ship.

load_lib

# Helper: make a stubbed "fake1"/"fake2" manager and register templates
# so that pkg_avail can route through the _run indirection.
register_fakes() {
  detect::mgr_register fake1 'fake1-avail {pkg}' '' 'fake1-ver {pkg}'
  detect::mgr_register fake2 'fake2-avail {pkg}' '' 'fake2-ver {pkg}'
  detect::mgr_register fake3 'fake3-avail {pkg}' '' 'fake3-ver {pkg}'
}

# ---------- active_managers ----------

detect::reset
detect::_which() { return 1; }   # no pkgmgrs present
assert::eq "$(detect::active_managers)" "" "active_managers: nothing installed"

# apt present → shows up.
detect::reset
detect::_which() { [[ $1 == apt-get ]]; }
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *apt*) printf '  ok   active_managers: apt listed when apt-get on PATH\n' ;;
  *)     printf '  FAIL active_managers: expected apt, got %q\n' "$out"
         ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# brew adds itself as secondary.
detect::reset
detect::_which() { case "$1" in apt-get|brew) return 0 ;; *) return 1 ;; esac; }
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *apt*brew*) printf '  ok   active_managers: apt + brew\n' ;;
  *)          printf '  FAIL active_managers: expected "apt brew", got %q\n' "$out"
              ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# snap is gated — default off.
detect::reset
detect::_which() { case "$1" in apt-get|snap) return 0 ;; *) return 1 ;; esac; }
detect::_run()   { case "$*" in "snap version") return 0 ;; *) return 1 ;; esac; }
unset DETECT_ALLOW_SNAP
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *snap*) printf '  FAIL active_managers: snap should be gated off by default\n'
          ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
  *)      printf '  ok   active_managers: snap gated off by default\n' ;;
esac

# snap included when DETECT_ALLOW_SNAP=1.
detect::reset
detect::_which() { case "$1" in apt-get|snap) return 0 ;; *) return 1 ;; esac; }
detect::_run()   { case "$*" in "snap version") return 0 ;; *) return 1 ;; esac; }
DETECT_ALLOW_SNAP=1
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *snap*) printf '  ok   active_managers: snap opted in\n' ;;
  *)      printf '  FAIL active_managers: snap missing with DETECT_ALLOW_SNAP=1\n'
          ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac
unset DETECT_ALLOW_SNAP

# ---------- pkg_resolve ----------

setup_resolver_host() {
  # Canonical test host: apt + brew active. No snap.
  # Override the default apt/brew version templates with simpler strings
  # so test stubs don't need to reason about \${Version}-style quoting.
  detect::reset
  register_fakes
  detect::mgr_register apt  'apt-cache show {pkg}'       '' 'apt-version {pkg}'
  detect::mgr_register brew 'brew info --formula {pkg}'  '' 'brew-version {pkg}'
  detect::_which() { case "$1" in apt-get|brew) return 0 ;; *) return 1 ;; esac; }
  unset DETECT_ALLOW_SNAP DETECT_OPT_OUT
}

# Empty candidate entry → unresolved.
setup_resolver_host
__DETECT_CANDIDATES[nothing]=""
assert::fail "pkg_resolve: no candidates → unresolved" detect::pkg_resolve nothing

# Unknown capability key → unresolved.
setup_resolver_host
assert::fail "pkg_resolve: unknown capability → unresolved" detect::pkg_resolve never-defined

# First candidate's manager not active → skips to second.
setup_resolver_host
__DETECT_CANDIDATES[editor]='
dnf:nano
apt:nano
'
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'apt-cache show nano') return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}
out=$(detect::pkg_resolve editor)
assert::eq "$out" "apt nano" "pkg_resolve: skips inactive mgr, picks apt"

# First candidate's manager present but pkg not in index → skips.
setup_resolver_host
__DETECT_CANDIDATES[editor]='
apt:missing-editor
apt:real-editor
'
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'apt-cache show real-editor')    return 0 ;;
      'apt-cache show missing-editor') return 1 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}
out=$(detect::pkg_resolve editor)
assert::eq "$out" "apt real-editor" "pkg_resolve: skips unavailable pkg"

# min_version respected: candidate at v1.0, min=2.0 → skip.
setup_resolver_host
__DETECT_CANDIDATES[big]='
apt:tool:2.0
apt:tool-backport
'
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'apt-cache show tool')          return 0 ;;
      'apt-version tool')             echo "1.0"; return 0 ;;
      'apt-cache show tool-backport') return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}
out=$(detect::pkg_resolve big)
assert::eq "$out" "apt tool-backport" "pkg_resolve: min_version skip → falls through"

# min_version met: candidate at v3.0, min=2.0 → accept.
setup_resolver_host
__DETECT_CANDIDATES[big]='
apt:tool:2.0
'
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'apt-cache show tool')  return 0 ;;
      'apt-version tool')     echo "3.0"; return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}
out=$(detect::pkg_resolve big)
assert::eq "$out" "apt tool" "pkg_resolve: min_version met → accept"

# DETECT_OPT_OUT skips a manager even when present+available.
setup_resolver_host
DETECT_OPT_OUT="apt"
__DETECT_CANDIDATES[editor]='
apt:nano
brew:nano
'
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'apt-cache show nano')             return 0 ;;
      'brew info --formula nano')        return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}
out=$(detect::pkg_resolve editor)
assert::eq "$out" "brew nano" "pkg_resolve: DETECT_OPT_OUT skips apt → falls to brew"
unset DETECT_OPT_OUT

# Comments and blank lines in the candidate block are ignored.
setup_resolver_host
__DETECT_CANDIDATES[editor]='
# leading comment

# mid-block comment
apt:nano
'
detect::_run() {
  if [[ $1 == bash && $2 == -c && $3 == 'apt-cache show nano' ]]; then return 0
  fi
  return 1
}
out=$(detect::pkg_resolve editor)
assert::eq "$out" "apt nano" "pkg_resolve: comments + blank lines ignored"

# All candidate managers absent → unresolved.
setup_resolver_host
__DETECT_CANDIDATES[editor]='
dnf:nano
pacman:nano
'
assert::fail "pkg_resolve: no active manager matches → unresolved" detect::pkg_resolve editor

# Snap candidate skipped by default, picked when DETECT_ALLOW_SNAP=1.
detect::reset
register_fakes
detect::_which() { case "$1" in snap|apt-get) return 0 ;; *) return 1 ;; esac; }
detect::_run() {
  case "$*" in
    "snap version") return 0 ;;
  esac
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'snap info lxd')  return 0 ;;
      'apt-cache show lxd') return 0 ;;
    esac
  fi
  return 1
}
detect::mgr_register snap 'snap info {pkg}' 'snap list {pkg}' ''
__DETECT_CANDIDATES[lxd]='
snap:lxd
apt:lxd
'

unset DETECT_ALLOW_SNAP
out=$(detect::pkg_resolve lxd)
assert::eq "$out" "apt lxd" "pkg_resolve: snap gated off by default → falls to apt"

DETECT_ALLOW_SNAP=1
out=$(detect::pkg_resolve lxd)
assert::eq "$out" "snap lxd" "pkg_resolve: DETECT_ALLOW_SNAP=1 → picks snap first"
unset DETECT_ALLOW_SNAP

# ---------- detect-packages.sh loads cleanly ----------

load_lib
if . "$(command dirname "$DETECT_LIB")/detect-packages.sh" 2>/dev/null; then
  printf '  ok   detect-packages.sh: sources without error\n'
else
  printf '  FAIL detect-packages.sh: source error\n'
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi

# Known capability landed.
if [[ -n "${__DETECT_CANDIDATES[c_toolchain]:-}" ]]; then
  printf '  ok   detect-packages.sh: c_toolchain entry present\n'
else
  printf '  FAIL detect-packages.sh: c_toolchain entry missing\n'
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi

if [[ "${__DETECT_CANDIDATES[c_toolchain]}" == *"apt:build-essential"* ]]; then
  printf '  ok   detect-packages.sh: apt:build-essential row present\n'
else
  printf '  FAIL detect-packages.sh: expected apt:build-essential in c_toolchain\n'
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi

# Idempotent re-source.
if . "$(command dirname "$DETECT_LIB")/detect-packages.sh" 2>/dev/null; then
  printf '  ok   detect-packages.sh: re-source is a no-op\n'
else
  printf '  FAIL detect-packages.sh: re-source errored\n'
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi
