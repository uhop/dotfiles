# test_diagnostics.sh — detect::summary + detect::report_json output.
#
# Stubs the _which / _run / _user indirection points so that probes return
# deterministic values regardless of the host running the tests. Asserts
# on key lines / fields; does not snapshot the full output (keeping tests
# resilient to cosmetic tweaks).

load_lib

# ---------- Shared stubs ----------

# Returns a canned profile of "Ubuntu 24.04 host with apt + snap + nopasswd
# sudo + ipv6 + no container + no WSL + no brew/flatpak/nix + npm present".
# Individual tests can override after calling this.
setup_ubuntu_host() {
  use_fixture ubuntu-24.04

  detect::_which() {
    case "$1" in
      apt-get|snap|npm|ip|sudo) return 0 ;;
      *) return 1 ;;
    esac
  }
  detect::_run() {
    case "$*" in
      "uname -m")                       echo x86_64 ;;
      "uname -s")                       echo Linux ;;
      "snap version")                   return 0 ;;
      "id -nG testuser")                echo "testuser sudo" ;;
      "sudo -n true")                   return 0 ;;
      "timeout 3 ip -6 route get "*)    return 0 ;;
      *) return 1 ;;
    esac
  }
  detect::_user() { echo testuser; }
  # Prevent the systemd-run path from finding a real /run/systemd/system.
  DETECT_SYSTEMD_RUN=/nonexistent
  DETECT_OSTREE_BOOTED=/nonexistent
  DETECT_OPENRC_SOFTLEVEL=/nonexistent
  DETECT_DOCKERENV=/nonexistent
  DETECT_WSL_BINFMT=/nonexistent
  unset WSL_DISTRO_NAME WSL_INTEROP container
}

# ---------- detect::summary ----------

setup_ubuntu_host
out=$(detect::summary)

case "$out" in
  *"Distro:"*"ubuntu 24.04 (debian family)"*)
    printf '  ok   summary: distro line\n' ;;
  *)
    printf '  FAIL summary: distro line not found\n  %s\n' "$out"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Kernel:"*"Linux x86_64"*)
    printf '  ok   summary: kernel line\n' ;;
  *)
    printf '  FAIL summary: kernel line missing\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Pkgmgrs:"*"apt"*)
    printf '  ok   summary: pkgmgrs list\n' ;;
  *)
    printf '  FAIL summary: expected "apt" in Pkgmgrs line\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Primary pkgmgr:"*"apt"*)
    printf '  ok   summary: primary pkgmgr\n' ;;
  *)
    printf '  FAIL summary: primary pkgmgr missing\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Sudo group:"*"sudo"*)
    printf '  ok   summary: sudo group\n' ;;
  *)
    printf '  FAIL summary: sudo group missing\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Sudo nopasswd:"*"yes"*)
    printf '  ok   summary: nopasswd yes\n' ;;
  *)
    printf '  FAIL summary: nopasswd expected yes\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Lang pkgmgrs:"*"npm"*)
    printf '  ok   summary: lang pkgmgrs lists npm\n' ;;
  *)
    printf '  FAIL summary: lang pkgmgrs missing\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# Bare host (no managers, no sudo group) — fall-through strings.
detect::reset
detect::_which() { return 1; }
detect::_run() {
  case "$*" in
    "uname -m") echo x86_64 ;;
    "uname -s") echo Linux ;;
    "id -nG testuser") echo "testuser" ;;
    *) return 1 ;;
  esac
}
detect::_user() { echo testuser; }
out=$(detect::summary)

case "$out" in
  *"Pkgmgrs:"*"(none)"*)
    printf '  ok   summary: empty pkgmgrs → (none)\n' ;;
  *)
    printf '  FAIL summary: empty pkgmgrs should be (none)\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Sudo group:"*"(none)"*)
    printf '  ok   summary: empty sudo group → (none)\n' ;;
  *)
    printf '  FAIL summary: empty sudo group should be (none)\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

case "$out" in
  *"Lang pkgmgrs:"*"(none)"*)
    printf '  ok   summary: empty lang pkgmgrs → (none)\n' ;;
  *)
    printf '  FAIL summary: empty lang pkgmgrs should be (none)\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- detect::report_json ----------

setup_ubuntu_host
json=$(detect::report_json)

# Brace framing.
case "$json" in
  '{'*'}')
    printf '  ok   report_json: wrapped in braces\n' ;;
  *)
    printf '  FAIL report_json: missing {} framing\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

assert_contains() {
  local label=$1 needle=$2
  if [[ $json == *"$needle"* ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s (missing: %q)\n' "$label" "$needle"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
}

assert_contains 'report_json: pkgmgr apt'           '"pkgmgr": "apt"'
assert_contains 'report_json: pkgmgrsPresent array' '"pkgmgrsPresent": ["apt"]'
assert_contains 'report_json: family debian'        '"family": "debian"'
assert_contains 'report_json: id ubuntu'            '"id": "ubuntu"'
assert_contains 'report_json: versionId 24.04'      '"versionId": "24.04"'
assert_contains 'report_json: arch string'          '"arch": "x86_64"'
assert_contains 'report_json: uname Linux'          '"uname": "Linux"'
assert_contains 'report_json: sudoGroup sudo'       '"sudoGroup": "sudo"'

# Booleans are unquoted literals, not strings.
assert_contains 'report_json: bool canSudoNopasswd true' '"canSudoNopasswd": true'
assert_contains 'report_json: bool hasSnap true'         '"hasSnap": true'
assert_contains 'report_json: bool hasBrew false'        '"hasBrew": false'
assert_contains 'report_json: bool isImmutable false'    '"isImmutable": false'

case "$json" in
  *'"canSudoNopasswd": "true"'*|*'"hasSnap": "true"'*|*'"hasBrew": "false"'*)
    printf '  FAIL report_json: bools must not be quoted strings\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
  *)
    printf '  ok   report_json: bools are JSON literals, not strings\n' ;;
esac

# Empty pkgmgrs → []. Force all _which calls to miss.
detect::reset
detect::_which() { return 1; }
detect::_run() {
  case "$*" in
    "uname -m") echo x86_64 ;;
    "uname -s") echo Linux ;;
    "id -nG testuser") echo testuser ;;
    *) return 1 ;;
  esac
}
detect::_user() { echo testuser; }
json=$(detect::report_json)
case "$json" in
  *'"pkgmgrsPresent": []'*)
    printf '  ok   report_json: empty pkgmgrs → []\n' ;;
  *)
    printf '  FAIL report_json: expected empty array for pkgmgrsPresent\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac
case "$json" in
  *'"pkgmgr": "unknown"'*)
    printf '  ok   report_json: no pkgmgr → "unknown"\n' ;;
  *)
    printf '  FAIL report_json: expected "pkgmgr": "unknown"\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- JSON string escaping ----------

# Install a fixture with a NAME value containing a double-quote so we can
# verify _json_escape emits \" rather than bare ".
tmpfix=$(mktemp)
cat >|"$tmpfix" <<'EOF'
ID=testdistro
ID_LIKE=debian
VERSION_ID=1.0
NAME="Tricky \"quoted\" name"
EOF
OS_RELEASE_PATH=$tmpfix
load_lib
detect::_which() { return 1; }
detect::_run() {
  case "$*" in
    "uname -m") echo x86_64 ;;
    "uname -s") echo Linux ;;
    "id -nG testuser") echo testuser ;;
    *) return 1 ;;
  esac
}
detect::_user() { echo testuser; }
json=$(detect::report_json)
rm -f "$tmpfix"

# NB: os-release spec already uses shell-escape conventions. Our parser
# strips the outer quotes but keeps the inner `\"` as literal backslash-quote
# in memory, which becomes `\\\"` after _json_escape escapes the backslash
# and then escapes the quote.
case "$json" in
  *'"name": "Tricky \\\"quoted\\\" name"'*)
    printf '  ok   report_json: quote + backslash escape\n' ;;
  *)
    printf '  FAIL report_json: quote escaping — got no match for expected pattern\n       json: %s\n' "$json"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)) ;;
esac

# ---------- Validate with jq if available ----------

if command -v jq >/dev/null 2>&1; then
  setup_ubuntu_host
  if detect::report_json | jq -e . >/dev/null 2>&1; then
    printf '  ok   report_json: valid JSON per jq\n'
  else
    printf '  FAIL report_json: jq rejected the output\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
else
  printf '  ok   report_json: jq not available on host — validation skipped\n'
fi
