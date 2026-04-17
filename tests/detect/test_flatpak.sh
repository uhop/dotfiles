# test_flatpak.sh — detect::flatpak_* probes (design §3.10.1.1).
#
# Replaces the former /tmp flatpak-install-unit-test.sh harness; all the
# same scenarios run here under the shared test harness. Absorbed into
# the detect-distro library 2026-04-17.

load_lib

# Per-test cleanup between cases — not all of detect::flatpak_* is in
# __DETECT_CACHE, so we explicitly reset the env vars and function stubs.
setup_flatpak_host() {
  detect::reset
  DETECT_FLATPAK_POLKIT_RULE=""
  DETECT_USER_OVERRIDE=testuser
  # Flatpak probes call `detect::_run flatpak …`. Default-stub both _which
  # and _run so tests that don't care about them don't fall through to
  # the real commands on the host.
  detect::_which() { return 1; }
  detect::_run()   { return 1; }
}

# ---------- has_polkit_rule ----------

setup_flatpak_host
tmpf=$(mktemp)
DETECT_FLATPAK_POLKIT_RULE=$tmpf
assert::ok "has_polkit_rule: file exists" detect::flatpak_has_polkit_rule
command rm -f "$tmpf"

setup_flatpak_host
DETECT_FLATPAK_POLKIT_RULE=/nonexistent/path
assert::fail "has_polkit_rule: file missing" detect::flatpak_has_polkit_rule

# ---------- in_sudo_group ----------

setup_flatpak_host
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser sudo adm" ;;
  esac
}
assert::ok "in_sudo_group: user in sudo" detect::flatpak_in_sudo_group

setup_flatpak_host
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser wheel" ;;
  esac
}
assert::ok "in_sudo_group: user in wheel" detect::flatpak_in_sudo_group

setup_flatpak_host
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser admin" ;;
  esac
}
assert::fail "in_sudo_group: admin alone doesn't count (Linux-only rule)" detect::flatpak_in_sudo_group

setup_flatpak_host
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser plain" ;;
  esac
}
assert::fail "in_sudo_group: no sudo/wheel membership" detect::flatpak_in_sudo_group

# ---------- can_system ----------

# Path A: polkit rule + sudo group → OK (no sudo needed, polkit authorizes).
setup_flatpak_host
tmpf=$(mktemp); DETECT_FLATPAK_POLKIT_RULE=$tmpf
detect::_which() { [[ $1 == sudo ]]; }
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser sudo" ;;
    "sudo -n true")    return 1 ;;
  esac
}
assert::ok "can_system: polkit rule + sudo group" detect::flatpak_can_system
command rm -f "$tmpf"

# Path B: no polkit rule but passwordless sudo → OK (sudo-wrap path).
setup_flatpak_host
DETECT_FLATPAK_POLKIT_RULE=/nonexistent
detect::_which() { [[ $1 == sudo ]]; }
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser plain" ;;
    "sudo -n true")    return 0 ;;
  esac
}
assert::ok "can_system: nopass sudo fallback" detect::flatpak_can_system

# Neither → fail.
setup_flatpak_host
DETECT_FLATPAK_POLKIT_RULE=/nonexistent
detect::_which() { [[ $1 == sudo ]]; }
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser plain" ;;
    "sudo -n true")    return 1 ;;
  esac
}
assert::fail "can_system: no polkit, no nopass sudo" detect::flatpak_can_system

# ---------- system_needs_sudo ----------

# Polkit rule + sudo group → plain flatpak install --system works; no sudo needed.
setup_flatpak_host
tmpf=$(mktemp); DETECT_FLATPAK_POLKIT_RULE=$tmpf
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser sudo" ;;
  esac
}
assert::fail "system_needs_sudo: polkit path → no wrap" detect::flatpak_system_needs_sudo
command rm -f "$tmpf"

# No polkit rule → sudo-wrap required.
setup_flatpak_host
DETECT_FLATPAK_POLKIT_RULE=/nonexistent
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser sudo" ;;
  esac
}
assert::ok "system_needs_sudo: no polkit → wrap" detect::flatpak_system_needs_sudo

# In sudo group but polkit rule missing → wrap needed.
setup_flatpak_host
DETECT_FLATPAK_POLKIT_RULE=/nonexistent
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser wheel" ;;
  esac
}
assert::ok "system_needs_sudo: wheel but no polkit → wrap" detect::flatpak_system_needs_sudo

# ---------- chosen_scope ----------

# Can system → system.
setup_flatpak_host
tmpf=$(mktemp); DETECT_FLATPAK_POLKIT_RULE=$tmpf
detect::_which() { [[ $1 == sudo ]]; }
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser sudo" ;;
  esac
}
assert::eq "$(detect::flatpak_chosen_scope)" "system" "chosen_scope: system when viable"
command rm -f "$tmpf"

# Cannot system → user.
setup_flatpak_host
DETECT_FLATPAK_POLKIT_RULE=/nonexistent
detect::_which() { return 1; }
detect::_run() {
  case "$*" in
    "id -nG testuser") echo "testuser plain" ;;
  esac
}
assert::eq "$(detect::flatpak_chosen_scope)" "user" "chosen_scope: user fallback"

# ---------- scope_of ----------

setup_flatpak_host
detect::_run() {
  case "$*" in
    "flatpak info --system org.foo") return 0 ;;   # installed system
    "flatpak info --user   org.foo") return 1 ;;
    "flatpak info --system org.bar") return 1 ;;
    "flatpak info --user org.bar")   return 0 ;;   # installed user
    "flatpak info --system org.nope") return 1 ;;
    "flatpak info --user org.nope")   return 1 ;;
  esac
  return 1
}
assert::eq "$(detect::flatpak_scope_of org.foo)"  "system" "scope_of: system install"
assert::eq "$(detect::flatpak_scope_of org.bar)"  "user"   "scope_of: user install"
assert::eq "$(detect::flatpak_scope_of org.nope)" "none"   "scope_of: not installed"

# ---------- has_remote ----------

setup_flatpak_host
detect::_run() {
  case "$*" in
    "flatpak remotes --system --columns=name") echo flathub ;;
    "flatpak remotes --user --columns=name")   echo flathub-beta ;;
    "flatpak remotes --columns=name")          printf '%s\n' flathub flathub-beta ;;
  esac
}
assert::ok   "has_remote: flathub in system"           detect::flatpak_has_remote flathub system
assert::fail "has_remote: flathub not in user scope"   detect::flatpak_has_remote flathub user
assert::ok   "has_remote: flathub-beta in user scope"  detect::flatpak_has_remote flathub-beta user
assert::ok   "has_remote: any scope — both visible"    detect::flatpak_has_remote flathub
assert::fail "has_remote: missing remote"              detect::flatpak_has_remote nosuchremote
