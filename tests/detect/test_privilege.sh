# test_privilege.sh — _assert_no_sudo falsifiability guard (design §5.5).

load_lib

# Normal unprivileged invocation: no SUDO_USER, EUID != 0 → pass.
unset SUDO_USER
assert::ok "no SUDO_USER → pass"  detect::_assert_no_sudo

# Sudo-escalated invocation: SUDO_USER set, EUID != 0 → fail with message.
SUDO_USER=someone
# Capture the function directly rather than via assert::fail helpers so we
# can verify it writes to stderr. Redirect stderr to /dev/null for the
# exit-code check.
if ! detect::_assert_no_sudo 2>/dev/null; then
  printf '  ok   SUDO_USER set → fail\n'
else
  printf '  FAIL SUDO_USER set should have failed\n'
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi

# Confirm the error message reaches stderr.
err=$(detect::_assert_no_sudo 2>&1 >/dev/null || true)
case "$err" in
  *"library must not be invoked via sudo"*)
    printf '  ok   SUDO_USER error message on stderr\n'
    ;;
  *)
    printf '  FAIL expected "library must not be invoked via sudo" in stderr, got: %q\n' "$err"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
    ;;
esac
unset SUDO_USER

# Root invocation (EUID=0) with SUDO_USER set would still pass, but we
# can't easily simulate EUID=0 in a test without actually being root.
# Documented in the function comment; skipped here.
