# test_pkg_probes.sh — mgr_register + single-package probes (§3).
#
# Uses a synthetic manager name ("fake") so the tests don't depend on the
# default apt/dnf/etc. templates doing anything sensible. The only thing
# we care about here is the pkg_* contract:
#   - pkg_avail / pkg_has forward the template exit to the caller.
#   - pkg_version echoes stdout verbatim.
#   - pkg_meets combines avail + version + version_compare.
#
# Templates are exercised end-to-end: tests stub detect::_run and match on
# the expanded `bash -c "..."` invocation, confirming {pkg} substitution
# actually happened.

load_lib

# ---------- Substitution helper ----------

assert::eq "$(detect::_subst_pkg 'foo {pkg} bar'       'xyz')" "foo xyz bar"      "_subst_pkg: single {pkg}"
assert::eq "$(detect::_subst_pkg 'xx {pkg} yy {pkg}'   'abc')" "xx abc yy abc"    "_subst_pkg: multiple {pkg}"
assert::eq "$(detect::_subst_pkg 'no placeholders'     'abc')" "no placeholders"  "_subst_pkg: no substitution"

# ---------- Unregistered manager → probes return false / empty ----------

detect::reset
detect::mgr_register ghost '' '' ''
assert::fail "pkg_avail: empty avail template → fail" detect::pkg_avail ghost foo
assert::fail "pkg_has:   empty has   template → fail" detect::pkg_has   ghost foo
assert::eq   "$(detect::pkg_version ghost foo)" "" "pkg_version: empty version template → empty stdout"

# Completely unregistered manager — arrays have no entry at all.
assert::fail "pkg_avail: unknown mgr → fail" detect::pkg_avail nosuchmgr foo
assert::fail "pkg_has:   unknown mgr → fail" detect::pkg_has   nosuchmgr foo
assert::eq   "$(detect::pkg_version nosuchmgr foo)" "" "pkg_version: unknown mgr → empty"

# ---------- pkg_avail / pkg_has happy path ----------

detect::reset
detect::mgr_register fake \
  'fake-avail {pkg}' \
  'fake-has {pkg}' \
  'fake-ver {pkg}'

detect::_run() {
  # All templates are dispatched via `bash -c "<expanded>"`. Match on the
  # inner expanded command to confirm substitution happened.
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'fake-avail foo'|'fake-avail old'|'fake-avail future'|'fake-avail weird'|'fake-avail noversion') return 0 ;;
      'fake-avail missing')                        return 1 ;;
      'fake-has foo')                              return 0 ;;
      'fake-has uninstalled')                      return 1 ;;
      'fake-ver foo')                              echo 2.0.11; return 0 ;;
      'fake-ver old')                              echo 1.0.0;  return 0 ;;
      'fake-ver future')                           echo 3.5.0;  return 0 ;;
      'fake-ver noversion')                        return 1 ;;
      'fake-ver weird')                            echo "1:2.34.1-1ubuntu1.9"; return 0 ;;
      *) return 1 ;;
    esac
  else
    return 1
  fi
}

assert::ok   "pkg_avail: present"   detect::pkg_avail fake foo
assert::fail "pkg_avail: missing"   detect::pkg_avail fake missing
assert::ok   "pkg_has:   installed" detect::pkg_has   fake foo
assert::fail "pkg_has:   not"       detect::pkg_has   fake uninstalled

assert::eq "$(detect::pkg_version fake foo)"    "2.0.11"  "pkg_version: clean"
assert::eq "$(detect::pkg_version fake weird)"  "1:2.34.1-1ubuntu1.9"  "pkg_version: passthrough of packaging tail"
assert::eq "$(detect::pkg_version fake noversion)" ""     "pkg_version: failing template → empty"

# ---------- pkg_meets: no min → same as pkg_avail ----------

assert::ok   "pkg_meets: no min, present → true"  detect::pkg_meets fake foo ""
assert::fail "pkg_meets: no min, missing → false" detect::pkg_meets fake missing ""

# ---------- pkg_meets: version comparison ----------

# 2.0.11 >= 2.0.0 → true
assert::ok   "pkg_meets: 2.0.11 >= 2.0.0"  detect::pkg_meets fake foo 2.0.0
# 2.0.11 >= 2.0.11 → true (equal)
assert::ok   "pkg_meets: 2.0.11 >= 2.0.11" detect::pkg_meets fake foo 2.0.11
# 2.0.11 >= 2.0.12 → false
assert::fail "pkg_meets: 2.0.11 < 2.0.12"  detect::pkg_meets fake foo 2.0.12
# 2.0.11 >= 3.0.0 → false
assert::fail "pkg_meets: 2.0.11 < 3.0.0"   detect::pkg_meets fake foo 3.0.0
# old (1.0.0) vs min 2.0.0 → false
assert::fail "pkg_meets: 1.0.0 < 2.0.0"    detect::pkg_meets fake old 2.0.0
# future (3.5.0) vs min 2.0.0 → true
assert::ok   "pkg_meets: 3.5.0 >= 2.0.0"   detect::pkg_meets fake future 2.0.0

# pkg_meets on packaging-tailed version: 1:2.34.1-1ubuntu1.9 normalizes to
# 2.34.1 (epoch stripped, packaging tail stripped) and should meet 2.34.
assert::ok   "pkg_meets: packaging tail normalized and >= min"  detect::pkg_meets fake weird 2.34.0
assert::fail "pkg_meets: packaging tail normalized < min"       detect::pkg_meets fake weird 2.35.0

# pkg_meets on missing pkg → always false, never reaches version check.
assert::fail "pkg_meets: missing pkg, any min → false"          detect::pkg_meets fake missing 1.0.0

# pkg_meets with `noversion`: avail says yes, version template fails → false
# (can't verify, don't guess).
assert::fail "pkg_meets: version template fails → false"  detect::pkg_meets fake noversion 2.0.0
# Same package, no min → short-circuits to avail success.
assert::ok   "pkg_meets: no version needed when min is empty"  detect::pkg_meets fake noversion ""

# ---------- Re-registration overrides previous entry ----------

detect::reset
detect::mgr_register fake 'first {pkg}' '' ''
detect::mgr_register fake 'second {pkg}' '' ''
detect::_run() {
  if [[ $1 == bash && $2 == -c && $3 == 'second foo' ]]; then return 0
  else return 1
  fi
}
assert::ok "mgr_register: re-registration replaces template" detect::pkg_avail fake foo

# ---------- Default registrations populated at source time ----------
#
# The assoc arrays can't be inspected from a `bash -c` subshell, so use
# inline bracket tests. Re-source the library to ensure the registrations
# block just ran.

load_lib

check_registered() {
  local mgr=$1 axis=$2 label=$3
  local -n arr="__DETECT_MGR_$axis"
  if [[ -n "${arr[$mgr]:-}" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s (%s[%s] is empty)\n' "$label" "__DETECT_MGR_$axis" "$mgr"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
}

check_registered apt    AVAIL 'mgr_register: apt is pre-registered'
check_registered dnf    AVAIL 'mgr_register: dnf is pre-registered'
check_registered pacman AVAIL 'mgr_register: pacman is pre-registered'
check_registered zypper AVAIL 'mgr_register: zypper is pre-registered'
check_registered apk    AVAIL 'mgr_register: apk is pre-registered'
check_registered brew   AVAIL 'mgr_register: brew is pre-registered'

# rpm-ostree has empty avail by design (defers to underlying dnf).
assert::eq "${__DETECT_MGR_AVAIL[rpm-ostree]}" "" "mgr_register: rpm-ostree avail is empty by design"
check_registered rpm-ostree           HAS   'mgr_register: rpm-ostree has template present'
check_registered transactional-update AVAIL 'mgr_register: transactional-update registered'

# ---------- Template substitution survives special chars in package names ----------

detect::reset
detect::mgr_register fake 'echo {pkg}' '' ''
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'echo lib-foo+bar') return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 1
}
assert::ok "pkg_avail: package name with +/-/." detect::pkg_avail fake 'lib-foo+bar'
