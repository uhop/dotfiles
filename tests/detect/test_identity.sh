# test_identity.sh — identity pass across every fixture.

# Each row: fixture  expected_id  expected_family  expected_version
cases=(
  "ubuntu-24.04       ubuntu               debian    24.04"
  "debian-12          debian               debian    12"
  "debian-13          debian               debian    13"
  "debian-sid         debian               debian    "
  "debian-slim        debian               debian    12"
  "linuxmint-21.3     linuxmint            debian    21.3"
  "fedora-43          fedora               rhel      43"
  "fedora-silverblue  fedora               rhel      43"
  "rocky-9            rocky                rhel      9.7"
  "almalinux-9        almalinux            rhel      9.7"
  "oracle-9           ol                   rhel      9.7"
  "amazonlinux-2023   amzn                 rhel      2023"
  "archlinux          arch                 arch      "
  "opensuse-tumbleweed opensuse-tumbleweed suse      20260415"
  "opensuse-microos   opensuse-microos     suse      20260415"
  "alpine-3.23        alpine               alpine    3.23.0"
  "alpine-edge        alpine               alpine    3.24.0_alpha20260415"
  "unknown            madeup               unknown   1.0"
)

for row in "${cases[@]}"; do
  read -r fixture exp_id exp_family exp_version <<<"$row"
  use_fixture "$fixture"
  assert::eq "$DETECTED_ID"         "$exp_id"      "$fixture: DETECTED_ID"
  assert::eq "$DETECTED_FAMILY"     "$exp_family"  "$fixture: DETECTED_FAMILY"
  assert::eq "$DETECTED_VERSION_ID" "$exp_version" "$fixture: DETECTED_VERSION_ID"
done

# family_contains — whole-word match, not substring (the os-release-parsing-pitfalls case).
use_fixture linuxmint-21.3
assert::ok   "linuxmint family_contains ubuntu"  detect::family_contains ubuntu
assert::ok   "linuxmint family_contains debian"  detect::family_contains debian
assert::fail "linuxmint family_contains rhel"    detect::family_contains rhel

use_fixture rocky-9
assert::ok   "rocky family_contains rhel"     detect::family_contains rhel
assert::ok   "rocky family_contains fedora"   detect::family_contains fedora
assert::fail "rocky family_contains debian"   detect::family_contains debian

# is_version_at_least — numeric compare on first integer component.
use_fixture debian-12
assert::ok   "debian-12 >= 12"  detect::is_version_at_least 12
assert::ok   "debian-12 >= 11"  detect::is_version_at_least 11
assert::fail "debian-12 >= 13"  detect::is_version_at_least 13

use_fixture fedora-43
assert::ok   "fedora-43 >= 40"  detect::is_version_at_least 40
assert::fail "fedora-43 >= 44"  detect::is_version_at_least 44

# Rolling distro — no VERSION_ID, should fail cleanly rather than error.
use_fixture archlinux
assert::fail "arch >= 1 (no VERSION_ID)"  detect::is_version_at_least 1

# Memoization — second call must not re-read OS_RELEASE_PATH.
use_fixture ubuntu-24.04
first_id=$DETECTED_ID
OS_RELEASE_PATH=/dev/null
detect::identity
assert::eq "$DETECTED_ID" "$first_id"  "identity is memoized (second call keeps value)"
