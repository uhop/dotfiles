# test_install.sh — pkg_install + _subst_pkgs (§3 install plumbing).

load_lib

# ---------- _subst_pkgs ----------

assert::eq "$(detect::_subst_pkgs 'sudo apt install -y {pkgs}' foo)" \
  "sudo apt install -y foo" \
  "_subst_pkgs: single pkg"

assert::eq "$(detect::_subst_pkgs 'sudo apt install -y {pkgs}' foo bar baz)" \
  "sudo apt install -y foo bar baz" \
  "_subst_pkgs: multiple pkgs"

assert::eq "$(detect::_subst_pkgs 'brew install {pkgs} && echo done {pkgs}' a b)" \
  "brew install a b && echo done a b" \
  "_subst_pkgs: multiple {pkgs} placeholders"

assert::eq "$(detect::_subst_pkgs 'no placeholder' a b)" \
  "no placeholder" \
  "_subst_pkgs: no substitution"

# ---------- pkg_install ----------

# No install template → fail.
detect::reset
detect::mgr_register ghost '' '' '' ''
assert::fail "pkg_install: empty template → fail" detect::pkg_install ghost foo

# Unknown manager → fail.
assert::fail "pkg_install: unknown mgr → fail" detect::pkg_install nosuchmgr foo

# Empty package list → success no-op, no command runs.
detect::reset
detect::mgr_register fake '' '' '' 'fake-install {pkgs}'
ran_it=0
detect::_run() { ran_it=1; return 0; }
detect::pkg_install fake
assert::eq "$ran_it" "0" "pkg_install: empty pkg list → no command"

# Single package invokes template.
detect::reset
detect::mgr_register fake '' '' '' 'fake-install {pkgs}'
captured=""
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then captured=$3; return 0; fi
  return 1
}
detect::pkg_install fake alpha
assert::eq "$captured" "fake-install alpha" "pkg_install: single pkg"

# Multiple packages batch into one call.
detect::reset
detect::mgr_register fake '' '' '' 'fake-install {pkgs}'
captured=""
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then captured=$3; return 0; fi
  return 1
}
detect::pkg_install fake alpha beta gamma
assert::eq "$captured" "fake-install alpha beta gamma" "pkg_install: multi-pkg batched"

# Install template exit status is forwarded.
detect::reset
detect::mgr_register fake '' '' '' 'fake-install {pkgs}'
detect::_run() { return 42; }
set +e
detect::pkg_install fake foo
rc=$?
set -e
assert::eq "$rc" "42" "pkg_install: forwards install command exit status"

# ---------- Default registrations now carry install templates ----------

load_lib

check_install() {
  local mgr=$1 label=$2 needle=$3
  local tmpl=${__DETECT_MGR_INSTALL[$mgr]:-}
  if [[ $tmpl == *"$needle"* ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s (template: %q)\n' "$label" "$tmpl"
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
  fi
}

check_install apt    'install: apt uses apt-get install -y'  'apt-get install -y {pkgs}'
check_install dnf    'install: dnf uses dnf install -y'      'dnf install -y {pkgs}'
check_install zypper 'install: zypper -n install'            'zypper -n install {pkgs}'
check_install pacman 'install: pacman -S --noconfirm'        'pacman -S --noconfirm --needed {pkgs}'
check_install apk    'install: apk add'                      'apk add {pkgs}'
check_install brew   'install: brew install (no sudo)'       'brew install {pkgs}'
check_install rpm-ostree 'install: rpm-ostree install -A'    'rpm-ostree install -A {pkgs}'
check_install transactional-update 'install: t-u pkg install' 'transactional-update -n pkg install {pkgs}'

# brew must NOT start with sudo.
if [[ "${__DETECT_MGR_INSTALL[brew]}" != sudo* ]]; then
  printf '  ok   install: brew template does not start with sudo\n'
else
  printf '  FAIL install: brew should not sudo\n'
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi
