# test_overrides.sh — apply_overrides + should_* predicates (design §3.8).

load_lib

# ---------- Rule 1: rhel + immutable + rpm-ostree → dnf disabled ----------

use_fixture fedora-silverblue
detect::_which() { case "$1" in rpm-ostree|dnf) return 0 ;; *) return 1 ;; esac; }
detect::_run() {
  case "$*" in
    "uname -s") echo Linux ;;
  esac
}
# Silverblue ships /run/ostree-booted → is_immutable true.
DETECT_OSTREE_BOOTED=/proc/1  # any existing path so -e returns true
detect::apply_overrides

out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *"rpm-ostree"*)
    case "$out" in
      *"dnf"*)
        printf '  FAIL rule 1: dnf should be disabled on Silverblue\n       active: %q\n' "$out"
        ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
      *)
        printf '  ok   rule 1: Silverblue disables dnf, keeps rpm-ostree\n' ;;
    esac ;;
  *)
    printf '  FAIL rule 1: rpm-ostree missing from active_managers\n       active: %q\n' "$out"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# Negative: standard Fedora Workstation — dnf only, no rpm-ostree → dnf
# stays enabled because is_immutable is false (presence of the rpm-ostree
# binary is itself one of the immutable-FS signals, so the negative case
# must have no rpm-ostree).
use_fixture fedora-43
detect::_which() { [[ $1 == dnf ]]; }
DETECT_OSTREE_BOOTED=/nonexistent
detect::apply_overrides
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *"dnf"*) printf '  ok   rule 1: non-immutable rhel keeps dnf\n' ;;
  *) printf '  FAIL rule 1: dnf should stay enabled on non-immutable rhel\n       active: %q\n' "$out"
     ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- Rule 2: suse + immutable + transactional-update → zypper disabled ----------

use_fixture opensuse-microos
detect::_which() { case "$1" in transactional-update|zypper) return 0 ;; *) return 1 ;; esac; }
DETECT_OSTREE_BOOTED=/nonexistent
detect::apply_overrides
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *"transactional-update"*)
    case "$out" in
      *"zypper"*)
        printf '  FAIL rule 2: zypper should be disabled on MicroOS\n       active: %q\n' "$out"
        ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
      *)
        printf '  ok   rule 2: MicroOS disables zypper, keeps transactional-update\n' ;;
    esac ;;
  *)
    printf '  FAIL rule 2: transactional-update missing\n       active: %q\n' "$out"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- Rule 5: unknown family + pkgmgr present → warn, proceed ----------

use_fixture unknown
detect::_which() { [[ $1 == apt-get ]]; }
stderr=$(detect::apply_overrides 2>&1 >/dev/null)
case "$stderr" in
  *"unknown family; proceeding with apt"*)
    printf '  ok   rule 5: unknown family warns with primary pkgmgr\n' ;;
  *)
    printf '  FAIL rule 5: expected warning for unknown family + apt\n       stderr: %s\n' "$stderr"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# No warning when family is known (debian).
use_fixture ubuntu-24.04
detect::_which() { [[ $1 == apt-get ]]; }
stderr=$(detect::apply_overrides 2>&1 >/dev/null)
if [[ -z $stderr ]]; then
  printf '  ok   rule 5: known family is silent\n'
else
  printf '  FAIL rule 5: expected no warning on known family\n       stderr: %s\n' "$stderr"
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi

# ---------- Idempotence: calling apply_overrides twice is safe ----------

use_fixture fedora-silverblue
detect::_which() { case "$1" in rpm-ostree|dnf) return 0 ;; *) return 1 ;; esac; }
DETECT_OSTREE_BOOTED=/proc/1
detect::apply_overrides
detect::apply_overrides
out=$(detect::active_managers | command tr '\n' ' ')
case "$out" in
  *"dnf"*)
    printf '  FAIL idempotence: dnf reappeared on second call\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
  *)
    printf '  ok   apply_overrides: idempotent across repeat calls\n' ;;
esac

# reset() clears the disabled state.
detect::reset
# After reset, no overrides applied → dnf would come back if we re-probed
# pkgmgrs_present with dnf visible. Confirm __DETECT_MGR_DISABLED was cleared.
if [[ ${#__DETECT_MGR_DISABLED[@]} -eq 0 ]]; then
  printf '  ok   reset: __DETECT_MGR_DISABLED cleared\n'
else
  printf '  FAIL reset: disabled map still has %d entries\n' "${#__DETECT_MGR_DISABLED[@]}"
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi

# ---------- should_skip_systemd (rule 3) ----------

detect::reset
# Container with no systemd → should_skip_systemd true.
DETECT_DOCKERENV=/proc/1
DETECT_SYSTEMD_RUN=/nonexistent
DETECT_OPENRC_SOFTLEVEL=/nonexistent
detect::_which() { return 1; }       # no runit / s6 / launchd
detect::_run()   { case "$*" in "uname -s") echo Linux ;; esac; }
assert::ok "should_skip_systemd: container + init=unknown" detect::should_skip_systemd

# Container but systemd inside → don't skip.
detect::reset
DETECT_DOCKERENV=/proc/1
DETECT_SYSTEMD_RUN=/proc/1     # "systemd run dir present"
DETECT_OPENRC_SOFTLEVEL=/nonexistent
detect::_which() { return 1; }
detect::_run()   { case "$*" in "uname -s") echo Linux ;; esac; }
assert::fail "should_skip_systemd: container with systemd inside → no-skip" detect::should_skip_systemd

# Bare metal → don't skip.
detect::reset
DETECT_DOCKERENV=/nonexistent
DETECT_SYSTEMD_RUN=/proc/1
unset container
detect::_which() { return 1; }
detect::_run()   { case "$*" in "uname -s") echo Linux ;; esac; }
assert::fail "should_skip_systemd: bare metal → no-skip" detect::should_skip_systemd

# ---------- should_force_ipv4 (rule 4) ----------

detect::reset
detect::_which() { [[ $1 == ip ]]; }
detect::_run() {
  case "$*" in
    "timeout 3 ip -6 route get 2606:4700:4700::1111") return 0 ;;
    "uname -s") echo Linux ;;
    *) return 1 ;;
  esac
}
assert::fail "should_force_ipv4: IPv6 available → no-force" detect::should_force_ipv4

detect::reset
detect::_which() { [[ $1 == ip ]]; }
detect::_run() {
  case "$*" in
    "timeout 3 ip -6 route get 2606:4700:4700::1111") return 1 ;;
    "uname -s") echo Linux ;;
    *) return 1 ;;
  esac
}
assert::ok "should_force_ipv4: no IPv6 → force" detect::should_force_ipv4
