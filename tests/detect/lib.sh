# lib.sh — shared assertion helpers for detect-distro.sh unit tests.
# Sourced by run-tests.sh and by each test_*.sh via the harness.

# Per-file fail counter (each test runs in its own subshell).
: "${ASSERT_FAIL_LOCAL:=0}"

assert::eq() {
  local actual=$1 expected=$2 label=${3:-}
  if [[ $actual == "$expected" ]]; then
    printf '  ok   %s\n' "${label:-$actual == $expected}"
  else
    printf '  FAIL %s\n       got: %q\n       want: %q\n' \
      "${label:-eq}" "$actual" "$expected"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
}

assert::ok() {
  local label=${1:-}
  shift || true
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "${label:-ok}"
  else
    printf '  FAIL %s (exit %d)\n' "${label:-ok}" "$?"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
}

assert::fail() {
  local label=${1:-}
  shift || true
  if ! "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "${label:-fail}"
  else
    printf '  FAIL %s (expected nonzero exit)\n' "${label:-fail}"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
}

# Source the library fresh. Clears __DETECT_DISTRO_LOADED so callers can
# re-source after changing OS_RELEASE_PATH.
load_lib() {
  unset __DETECT_DISTRO_LOADED
  # shellcheck disable=SC1090
  . "$DETECT_LIB"
  detect::reset
}

# Load a fixture by name, re-source the library, and run identity probe.
# Usage: use_fixture ubuntu-24.04
use_fixture() {
  OS_RELEASE_PATH="$FIXTURES_DIR/os-release/$1.env"
  [[ -r $OS_RELEASE_PATH ]] || {
    printf '  FAIL fixture not found: %s\n' "$OS_RELEASE_PATH"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
    return 1
  }
  load_lib
  detect::identity
}
