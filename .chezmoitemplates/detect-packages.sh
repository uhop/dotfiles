# detect-packages.sh — candidate tables for the detect-distro.sh resolver.
#
# Data, not code. Each entry maps a logical capability name to an ordered
# list of `mgr:name[:min_version]` tuples. detect::pkg_resolve walks the
# list and returns the first tuple whose manager is active and whose
# package query succeeds (optionally meeting a min_version bar).
#
# Ordering rules of thumb:
#   1. Native system managers first (apt, dnf, pacman, ...) — they're the
#      lightest integration path and the best-maintained packages on each
#      distro.
#   2. Secondary managers (brew, snap) last — only reached if no native
#      option exists or if all natives are opted out.
#   3. Within native managers, no particular order — pkg_resolve only
#      picks one per call, so the rest of the row is dead weight once the
#      first match lands.
#
# Sourcing contract: no side effects beyond populating __DETECT_CANDIDATES.
# Safe to source multiple times.
#
# This file assumes detect-distro.sh has already been sourced so that
# __DETECT_CANDIDATES is declared.

[[ ${__DETECT_PACKAGES_LOADED:-} == 1 ]] && return 0
__DETECT_PACKAGES_LOADED=1

# Defensive: create the array if detect-distro.sh wasn't sourced first, so
# sourcing-order mistakes don't produce a silent failure at resolve time.
declare -gA __DETECT_CANDIDATES 2>/dev/null || true

# ---- c_toolchain — gcc + g++ + make + libc headers, enough to build C/C++ ----
# On debian-family, `build-essential` bundles everything. On rpm-family the
# three components come as separate packages; we ship them as a comma-
# separated group so pkg_resolve returns all three and pkg_ensure installs
# them in one batched call.
__DETECT_CANDIDATES[c_toolchain]='
apt:build-essential
dnf:gcc,gcc-c++,make
zypper:gcc,gcc-c++,make
pacman:base-devel
apk:build-base
brew:gcc
'

# ---- micro_editor — the small-footprint modern terminal editor ----
__DETECT_CANDIDATES[micro_editor]='
apt:micro
dnf:micro
zypper:micro
pacman:micro
apk:micro
brew:micro
'

# ---- git — the VCS itself (usually pre-installed; present for completeness) ----
__DETECT_CANDIDATES[git]='
apt:git
dnf:git
zypper:git
pacman:git
apk:git
brew:git
'

# ---- jq — JSON query/filter tool ----
__DETECT_CANDIDATES[jq]='
apt:jq
dnf:jq
zypper:jq
pacman:jq
apk:jq
brew:jq
'

# ---- lxd — Canonical container manager; snap is the canonical channel on Ubuntu ----
# snap only appears here if DETECT_ALLOW_SNAP=1 (active_managers gates it).
__DETECT_CANDIDATES[lxd]='
snap:lxd
apt:lxd
'

# ---- kubectl — snap is Canonical's preferred distribution on Ubuntu ----
__DETECT_CANDIDATES[kubectl]='
snap:kubectl
apt:kubectl
dnf:kubectl
brew:kubernetes-cli
'

# ---- curl — network fetcher; consumer scripts assume it's present for
# Homebrew install, chezmoi bootstrap, etc. Most distros ship it pre-
# installed; RHEL minimal images have `curl-minimal` which provides the
# `curl` binary and conflicts with the full `curl` package, so we route
# to the *binary* presence rather than the package name on dnf (handled
# via a wrapper package `curl-minimal` that also satisfies the need). ----
__DETECT_CANDIDATES[curl]='
apt:curl
dnf:curl
zypper:curl
pacman:curl
apk:curl
brew:curl
'

# ---- git_gui — `git-gui` GUI commit browser ----
__DETECT_CANDIDATES[git_gui]='
apt:git-gui
dnf:git-gui
zypper:git-gui
pacman:tk
apk:git-gui
brew:git-gui
'

# ---- gitk — `gitk` commit-graph viewer ----
__DETECT_CANDIDATES[gitk]='
apt:gitk
dnf:gitk
zypper:git-gui
pacman:tk
apk:git-gui
brew:git-gui
'

# ---- brew_linux_prereqs — files Homebrew needs on RHEL-minimal hosts that
# debian-family images already bundle. Only surfaces on dnf/zypper/pacman/
# apk-based hosts where these tools aren't guaranteed; pkg_resolve simply
# returns empty for debian-family (no `apt:` candidate row). ----
__DETECT_CANDIDATES[brew_linux_prereqs]='
dnf:file,ca-certificates,tar,gzip,bzip2,xz,unzip,procps-ng,util-linux
zypper:file,ca-certificates,tar,gzip,bzip2,xz,unzip,procps,util-linux
pacman:file,ca-certificates,tar,gzip,bzip2,xz,unzip,procps-ng,util-linux
apk:file,ca-certificates,tar,gzip,bzip2,xz,unzip,procps,util-linux
'
