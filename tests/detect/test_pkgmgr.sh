# test_pkgmgr.sh — package-manager probes + family consistency.

load_lib

# ---------- pkgmgrs_present / pkgmgr ----------

detect::reset
detect::_which() { return 1; }
assert::eq "$(detect::pkgmgr)"          "unknown"  "pkgmgr: none → unknown"
assert::eq "$(detect::pkgmgrs_present)" ""         "pkgmgrs_present: empty"

detect::reset
detect::_which() { [[ $1 == apt-get ]]; }
assert::eq "$(detect::pkgmgr)"          "apt"  "pkgmgr: apt"
assert::eq "$(detect::pkgmgrs_present)" "apt"  "pkgmgrs_present: apt only"

# Multi-manager: apt + brew (apt is first native, brew is secondary).
detect::reset
detect::_which() { case "$1" in apt-get|brew) return 0 ;; *) return 1 ;; esac; }
expected="apt
brew"
assert::eq "$(detect::pkgmgrs_present)" "$expected"  "pkgmgrs_present: apt + brew"
assert::eq "$(detect::pkgmgr)"          "apt"        "pkgmgr: native wins over brew"

# Immutable priority: rpm-ostree wins over dnf even though both are sniffable.
detect::reset
detect::_which() { case "$1" in rpm-ostree|dnf) return 0 ;; *) return 1 ;; esac; }
expected="rpm-ostree
dnf"
assert::eq "$(detect::pkgmgrs_present)" "$expected"  "pkgmgrs_present: rpm-ostree wins priority"
assert::eq "$(detect::pkgmgr)"          "rpm-ostree" "pkgmgr: rpm-ostree primary on Silverblue"

# Dedup: dnf5 and dnf both sniffable → "dnf" appears once.
detect::reset
detect::_which() { case "$1" in dnf5|dnf) return 0 ;; *) return 1 ;; esac; }
assert::eq "$(detect::pkgmgrs_present)" "dnf"  "pkgmgrs_present: dnf5+dnf dedup to 'dnf'"

# Memoization: cached across _which swap.
detect::reset
detect::_which() { [[ $1 == apt-get ]]; }
detect::pkgmgrs_present >/dev/null
detect::_which() { return 1; }
assert::eq "$(detect::pkgmgrs_present)" "apt"  "pkgmgrs_present memoized"

# ---------- has_brew / has_flatpak / has_snap / has_nix ----------

detect::reset
detect::_which() { [[ $1 == brew ]]; }
assert::ok   "has_brew: brew present"  detect::has_brew

detect::reset
detect::_which() { return 1; }
assert::fail "has_brew: brew absent"   detect::has_brew

# Flatpak: needs binary AND at least one configured remote.
detect::reset
detect::_which() { [[ $1 == flatpak ]]; }
detect::_run() {
  case "$*" in
    "flatpak remotes --columns=name") echo flathub ;;
    *) return 1 ;;
  esac
}
assert::ok   "has_flatpak: binary + remote"  detect::has_flatpak

detect::reset
detect::_which() { [[ $1 == flatpak ]]; }
detect::_run() {
  case "$*" in
    "flatpak remotes --columns=name") echo "" ;;
    *) return 1 ;;
  esac
}
assert::fail "has_flatpak: binary but no remotes"  detect::has_flatpak

detect::reset
detect::_which() { return 1; }
assert::fail "has_flatpak: no binary"  detect::has_flatpak

# Snap: needs binary AND snapd responding.
detect::reset
detect::_which() { [[ $1 == snap ]]; }
detect::_run() { case "$*" in "snap version") return 0 ;; *) return 1 ;; esac; }
assert::ok   "has_snap: snap + daemon up"  detect::has_snap

detect::reset
detect::_which() { [[ $1 == snap ]]; }
detect::_run() { return 1; }
assert::fail "has_snap: snap + daemon down"  detect::has_snap

detect::reset
detect::_which() { return 1; }
assert::fail "has_snap: no snap binary"  detect::has_snap

# Nix: nix-env OR nix CLI.
detect::reset
detect::_which() { [[ $1 == nix-env ]]; }
assert::ok   "has_nix: nix-env"  detect::has_nix

detect::reset
detect::_which() { [[ $1 == nix ]]; }
assert::ok   "has_nix: nix"  detect::has_nix

detect::reset
detect::_which() { return 1; }
assert::fail "has_nix: neither"  detect::has_nix

# ---------- Language managers (thin presence checks) ----------

detect::reset
detect::_which() { [[ $1 == npm ]]; }
assert::ok "has_npm_global"  detect::has_npm_global

detect::reset
detect::_which() { [[ $1 == pip3 ]]; }
assert::ok "has_pip_user: pip3"  detect::has_pip_user

detect::reset
detect::_which() { [[ $1 == pip ]]; }
assert::ok "has_pip_user: pip fallback"  detect::has_pip_user

detect::reset
detect::_which() { [[ $1 == uv ]]; }
assert::ok "has_uv_tool"  detect::has_uv_tool

detect::reset
detect::_which() { [[ $1 == pipx ]]; }
assert::ok "has_pipx"  detect::has_pipx

detect::reset
detect::_which() { [[ $1 == cargo ]]; }
assert::ok "has_cargo"  detect::has_cargo

detect::reset
detect::_which() { [[ $1 == go ]]; }
assert::ok "has_go_install"  detect::has_go_install

# ---------- family_consistency ----------

# Debian + apt → consistent.
use_fixture ubuntu-24.04
detect::_which() { [[ $1 == apt-get ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "consistent"  "consistency: debian + apt"

# Rhel + dnf → consistent.
use_fixture fedora-43
detect::_which() { [[ $1 == dnf ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "consistent"  "consistency: rhel + dnf"

# Silverblue (rhel) + rpm-ostree → consistent.
use_fixture fedora-silverblue
detect::_which() { [[ $1 == rpm-ostree ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "consistent"  "consistency: Silverblue + rpm-ostree"

# MicroOS (suse) + transactional-update → consistent.
use_fixture opensuse-microos
detect::_which() { [[ $1 == transactional-update ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "consistent"  "consistency: MicroOS + transactional-update"

# Arch + pacman.
use_fixture archlinux
detect::_which() { [[ $1 == pacman ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "consistent"  "consistency: arch + pacman"

# Alpine + apk.
use_fixture alpine-3.23
detect::_which() { [[ $1 == apk ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "consistent"  "consistency: alpine + apk"

# Debian declared but no apt → inconsistent (warns, never blocks).
use_fixture ubuntu-24.04
detect::_which() { [[ $1 == dnf ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "inconsistent"  "consistency: debian declared, dnf present"

# Rhel declared but no system pkgmgr at all → inconsistent.
use_fixture fedora-43
detect::_which() { return 1; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "inconsistent"  "consistency: rhel declared, no pkgmgr"

# Unknown family → unknown (nothing to check against).
use_fixture unknown
detect::_which() { [[ $1 == apt-get ]]; }
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
assert::eq "$(detect::family_consistency)" "unknown"  "consistency: unknown family → unknown"

# Kernel/family mismatch: debian family + Darwin kernel → inconsistent.
use_fixture ubuntu-24.04
detect::_which() { [[ $1 == apt-get ]]; }
detect::_run() { case "$*" in "uname -s") echo Darwin ;; esac; }
assert::eq "$(detect::family_consistency)" "inconsistent"  "consistency: debian family + Darwin kernel"
