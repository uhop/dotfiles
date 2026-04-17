# detect-distro.sh — bootstrap detection library.
#
# Single source of truth for identity + capability detection. Consumed by
# bootstrap-dotfiles, .chezmoi.toml.tmpl (via output + includeTemplate),
# and run_onchange_* scripts (via template inline). See
# dev-docs/bootstrap-detection-design.md for the full design; this file
# is the implementation.
#
# Scope of this commit: Section 1 (Identity) + version utilities only.
# Section 2 (Capabilities) and Section 3 (Package resolution) land in
# follow-up commits within PR 1.
#
# Sourcing contract: no side effects. All behaviour is function-local.
# Safe to source multiple times (idempotency guard below).

# Idempotency guard — skip re-sourcing.
[[ ${__DETECT_DISTRO_LOADED:-} == 1 ]] && return 0
__DETECT_DISTRO_LOADED=1

# Overridable path to /etc/os-release. Tests point this at fixtures.
: "${OS_RELEASE_PATH:=/etc/os-release}"

#==============================================================================
# Internal helpers (prefixed _, monkey-patched by tests)
#==============================================================================

# 0 if the command is on PATH. Indirection point for tests.
detect::_which() {
  command -v "$1" >/dev/null 2>&1
}

# Run an external command and return its stdout + exit. Indirection point
# for tests that need to canned-return non-filesystem command output.
detect::_run() {
  "$@"
}

# Probe a URL with HEAD within a short timeout. Indirection point for
# tests so network reachability checks don't actually touch the network.
detect::_net_get() {
  curl --max-time 5 -sI "$1" >/dev/null 2>&1
}

# Current user name. DETECT_USER_OVERRIDE pins it for tests.
detect::_user() {
  if [[ -n ${DETECT_USER_OVERRIDE:-} ]]; then
    echo "$DETECT_USER_OVERRIDE"
  else
    id -un
  fi
}

# Memoization cache — keyed by probe name. `detect::reset` clears it.
declare -gA __DETECT_CACHE=()

# Paths probed in Section 2 — overridable for tests so filesystem-dependent
# checks can point at a tmpdir.
: "${DETECT_SYSTEMD_RUN:=/run/systemd/system}"
: "${DETECT_OSTREE_BOOTED:=/run/ostree-booted}"
: "${DETECT_OPENRC_SOFTLEVEL:=/run/openrc/softlevel}"
: "${DETECT_DOCKERENV:=/.dockerenv}"
: "${DETECT_WSL_BINFMT:=/proc/sys/fs/binfmt_misc/WSLInterop}"

#==============================================================================
# Section 1 — Identity (name-based, Pass 1)
#==============================================================================

# Populate DETECTED_* vars from $OS_RELEASE_PATH. Memoized.
# Exports: DETECTED_ID, DETECTED_ID_LIKE, DETECTED_VERSION_ID,
#          DETECTED_VARIANT_ID, DETECTED_NAME, DETECTED_FAMILY
detect::identity() {
  [[ -n ${__DETECT_CACHE[identity]:-} ]] && return 0

  DETECTED_ID=""
  DETECTED_ID_LIKE=""
  DETECTED_VERSION_ID=""
  DETECTED_VARIANT_ID=""
  DETECTED_NAME=""
  DETECTED_FAMILY="unknown"

  if [[ -r $OS_RELEASE_PATH ]]; then
    # Source in a subshell via eval on filtered content so we don't leak
    # unrelated vars or execute unexpected code. os-release is shell-safe
    # by spec but values are double-quoted; awk strips comments + blanks.
    local line key val
    while IFS= read -r line; do
      [[ $line == \#* || -z $line ]] && continue
      [[ $line != *=* ]] && continue
      key=${line%%=*}
      val=${line#*=}
      # Strip surrounding double or single quotes.
      if [[ ${val:0:1} == '"' && ${val: -1} == '"' ]]; then
        val=${val:1:-1}
      elif [[ ${val:0:1} == "'" && ${val: -1} == "'" ]]; then
        val=${val:1:-1}
      fi
      case "$key" in
        ID)          DETECTED_ID=$val ;;
        ID_LIKE)     DETECTED_ID_LIKE=$val ;;
        VERSION_ID)  DETECTED_VERSION_ID=$val ;;
        VARIANT_ID)  DETECTED_VARIANT_ID=$val ;;
        NAME)        DETECTED_NAME=$val ;;
      esac
    done <"$OS_RELEASE_PATH"
  fi

  DETECTED_FAMILY=$(detect::_derive_family "$DETECTED_ID" "$DETECTED_ID_LIKE")

  __DETECT_CACHE[identity]=1
  return 0
}

# Derive a coarse family label from ID + ID_LIKE.
#
# Family is a DIAGNOSTIC label, not a router. Package operations are driven
# by sniffed package-manager presence (detect::pkgmgr, landing in a later
# commit) — not by family. Family is used only for genuinely family-scoped
# semantics that aren't derivable from a pkgmgr check (SELinux defaults,
# /etc/default/* layout, systemd unit conventions).
#
# The match arms rely on derivatives self-declaring ID_LIKE rather than
# listing every downstream distro by name:
#   - ubuntu/mint/pop/zorin declare ID_LIKE containing "debian"
#   - rocky/alma/oracle/amazon declare ID_LIKE containing "fedora" or "rhel"
#   - opensuse-* (tumbleweed, leap, microos) + SLES declare ID_LIKE containing "suse"
#   - manjaro/endeavour/garuda declare ID_LIKE="arch"
# Truly novel distros with no familiar ID_LIKE fall through to `unknown`,
# which is the correct signal that family-scoped logic should not apply
# and capability probes should drive decisions instead.
#
# Darwin doesn't ship os-release; consumers check $(uname -s) separately.
detect::_derive_family() {
  local id=$1 id_like=$2
  local haystack=" $id $id_like "

  case "$haystack" in
    *" debian "*)  echo debian ;;
    *" fedora "*|*" rhel "*)  echo rhel ;;
    *" suse "*)  echo suse ;;
    *" arch "*)  echo arch ;;
    *" alpine "*)  echo alpine ;;
    *)  echo unknown ;;
  esac
}

# 0 if $token appears as a whole word in ID or ID_LIKE.
# See topics/os-release-parsing-pitfalls — don't take the first word of
# ID_LIKE; treat the whole string as a set of tokens.
detect::family_contains() {
  detect::identity
  local token=$1
  local haystack=" $DETECTED_ID $DETECTED_ID_LIKE "
  [[ $haystack == *" $token "* ]]
}

# 0 if VERSION_ID >= $min. Compares the first integer component only.
# Sufficient for "Fedora >= 40" / "Debian >= 12" style checks; not for
# point releases (use pkg_meets for those).
detect::is_version_at_least() {
  detect::identity
  local min=$1
  local cur=${DETECTED_VERSION_ID%%.*}
  [[ -z $cur ]] && return 1
  # Guard against non-numeric VERSION_ID (rolling distros like arch).
  [[ $cur =~ ^[0-9]+$ ]] || return 1
  (( cur >= min ))
}

#==============================================================================
# Section 2 — Capabilities (sniffed, Pass 2)
#==============================================================================
#
# Capabilities drive behavior. DETECTED_FAMILY is a DIAGNOSTIC label only —
# never consulted here to pick a code path. detect::family_consistency
# (Section 2b, not yet landed) cross-checks sniffed state against the
# declared family and logs mismatches; it never blocks. See design doc
# §5 + project memory on capability-driven detection.

# 0 if <cmd> is on PATH. Memoized per-name.
detect::has_cmd() {
  local cmd=$1
  local key="has_cmd:$cmd"
  if [[ ${__DETECT_CACHE[$key]+set} == set ]]; then
    [[ ${__DETECT_CACHE[$key]} == 1 ]]
    return
  fi
  if detect::_which "$cmd"; then
    __DETECT_CACHE[$key]=1
    return 0
  fi
  __DETECT_CACHE[$key]=0
  return 1
}

# CPU architecture from `uname -m`. Echoes x86_64, aarch64, armv7l, etc.
detect::arch() {
  if [[ ${__DETECT_CACHE[arch]+set} != set ]]; then
    __DETECT_CACHE[arch]=$(detect::_run uname -m)
  fi
  echo "${__DETECT_CACHE[arch]}"
}

# Kernel identity from `uname -s`. Echoes Linux, Darwin, FreeBSD, etc.
detect::uname_s() {
  if [[ ${__DETECT_CACHE[uname_s]+set} != set ]]; then
    __DETECT_CACHE[uname_s]=$(detect::_run uname -s)
  fi
  echo "${__DETECT_CACHE[uname_s]}"
}

# Echoes systemd|openrc|runit|s6|launchd|unknown.
# Signal priority: Darwin → launchd; systemd runtime dir; openrc softlevel;
# specific binaries on PATH for runit/s6.
detect::init_system() {
  if [[ ${__DETECT_CACHE[init_system]+set} == set ]]; then
    echo "${__DETECT_CACHE[init_system]}"
    return 0
  fi
  local result=unknown
  if [[ $(detect::uname_s) == Darwin ]]; then
    result=launchd
  elif [[ -d $DETECT_SYSTEMD_RUN ]]; then
    result=systemd
  elif [[ -e $DETECT_OPENRC_SOFTLEVEL ]]; then
    result=openrc
  elif detect::has_cmd runit-init; then
    result=runit
  elif detect::has_cmd s6-svscan; then
    result=s6
  fi
  __DETECT_CACHE[init_system]=$result
  echo "$result"
}

# 0 if the root filesystem is immutable (read-only /usr family).
# Read-only signals only — never attempts a write (§5.2 in design).
detect::is_immutable() {
  if [[ ${__DETECT_CACHE[is_immutable]+set} == set ]]; then
    [[ ${__DETECT_CACHE[is_immutable]} == 1 ]]
    return
  fi
  local result=0
  if detect::has_cmd rpm-ostree \
    || detect::has_cmd transactional-update \
    || [[ -e $DETECT_OSTREE_BOOTED ]]; then
    result=1
  fi
  __DETECT_CACHE[is_immutable]=$result
  [[ $result == 1 ]]
}

# 0 if running inside a container (Docker, podman, LXC, systemd-nspawn).
detect::is_container() {
  if [[ ${__DETECT_CACHE[is_container]+set} == set ]]; then
    [[ ${__DETECT_CACHE[is_container]} == 1 ]]
    return
  fi
  local result=0
  if [[ -e $DETECT_DOCKERENV ]] || [[ -n ${container:-} ]]; then
    result=1
  elif detect::has_cmd systemd-detect-virt \
    && [[ -n "$(detect::_run systemd-detect-virt -c 2>/dev/null || true)" ]]; then
    result=1
  fi
  __DETECT_CACHE[is_container]=$result
  [[ $result == 1 ]]
}

# 0 if running on WSL (any version).
detect::is_wsl() {
  if [[ ${__DETECT_CACHE[is_wsl]+set} == set ]]; then
    [[ ${__DETECT_CACHE[is_wsl]} == 1 ]]
    return
  fi
  local result=0
  if [[ -n ${WSL_DISTRO_NAME:-} || -n ${WSL_INTEROP:-} ]] \
    || [[ -e $DETECT_WSL_BINFMT ]]; then
    result=1
  fi
  __DETECT_CACHE[is_wsl]=$result
  [[ $result == 1 ]]
}

# 0 if a real IPv6 route to a public host exists (via `ip -6 route get`).
# Uses `ip route get` rather than ping because ping needs CAP_NET_RAW.
# Target is Cloudflare's 2606:4700:4700::1111 — anycast, always up.
detect::has_ipv6() {
  if [[ ${__DETECT_CACHE[has_ipv6]+set} == set ]]; then
    [[ ${__DETECT_CACHE[has_ipv6]} == 1 ]]
    return
  fi
  local result=0
  if detect::has_cmd ip \
    && detect::_run timeout 3 ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    result=1
  fi
  __DETECT_CACHE[has_ipv6]=$result
  [[ $result == 1 ]]
}

# 0 if <url> responds to a HEAD request within 5s. Memoized per-URL.
detect::can_reach() {
  local url=$1
  local key="can_reach:$url"
  if [[ ${__DETECT_CACHE[$key]+set} == set ]]; then
    [[ ${__DETECT_CACHE[$key]} == 1 ]]
    return
  fi
  local result=0
  if detect::_net_get "$url"; then
    result=1
  fi
  __DETECT_CACHE[$key]=$result
  [[ $result == 1 ]]
}

# Echoes the first sudo-capable group the user belongs to, or empty if none.
# Candidates (in priority order): wheel, sudo, admin. Memoized.
detect::sudo_group() {
  if [[ ${__DETECT_CACHE[sudo_group]+set} == set ]]; then
    local v=${__DETECT_CACHE[sudo_group]}
    [[ $v == __NONE__ ]] && echo "" || echo "$v"
    return 0
  fi
  local user groups group
  user=$(detect::_user)
  groups=$(detect::_run id -nG "$user" 2>/dev/null || echo "")
  for group in wheel sudo admin; do
    if [[ " $groups " == *" $group "* ]]; then
      __DETECT_CACHE[sudo_group]=$group
      echo "$group"
      return 0
    fi
  done
  __DETECT_CACHE[sudo_group]=__NONE__
  echo ""
}

# 0 if passwordless sudo is currently usable.
detect::can_sudo_nopasswd() {
  if [[ ${__DETECT_CACHE[can_sudo_nopasswd]+set} == set ]]; then
    [[ ${__DETECT_CACHE[can_sudo_nopasswd]} == 1 ]]
    return
  fi
  local result=0
  if detect::has_cmd sudo && detect::_run sudo -n true 2>/dev/null; then
    result=1
  fi
  __DETECT_CACHE[can_sudo_nopasswd]=$result
  [[ $result == 1 ]]
}

#------------------------------------------------------------------------------
# Package manager probes
#------------------------------------------------------------------------------
#
# Ordered pairs: "sniff_binary:canonical_name". Priority is top-to-bottom.
# Immutable-FS managers come first so they win on hosts that have both
# (Silverblue ships rpm-ostree AND dnf; installs must go through the former).
# Traditional natives next, then secondary managers (brew, nix).
# Two sniffs may map to the same canonical ("dnf5" and "dnf") — pkgmgrs_present
# dedups canonicals on emit.
__DETECT_MGR_SNIFFS=(
  rpm-ostree:rpm-ostree
  transactional-update:transactional-update
  apt-get:apt
  dnf5:dnf
  dnf:dnf
  zypper:zypper
  pacman:pacman
  apk:apk
  xbps-install:xbps
  emerge:emerge
  eopkg:eopkg
  brew:brew
  nix-env:nix
)

# Echoes newline-separated list of detected system package managers in
# priority order, deduped by canonical name. Empty output if none found.
# Memoized.
detect::pkgmgrs_present() {
  if [[ ${__DETECT_CACHE[pkgmgrs_present]+set} == set ]]; then
    [[ -n ${__DETECT_CACHE[pkgmgrs_present]} ]] && echo "${__DETECT_CACHE[pkgmgrs_present]}"
    return 0
  fi
  local found=() seen=" " pair sniff mgr joined
  for pair in "${__DETECT_MGR_SNIFFS[@]}"; do
    sniff=${pair%%:*}
    mgr=${pair#*:}
    [[ $seen == *" $mgr "* ]] && continue
    if detect::has_cmd "$sniff"; then
      found+=("$mgr")
      seen+="$mgr "
    fi
  done
  joined=$(IFS=$'\n'; echo "${found[*]:-}")
  __DETECT_CACHE[pkgmgrs_present]=$joined
  [[ -n $joined ]] && echo "$joined"
  return 0
}

# Echoes the top-priority system manager, or `unknown`. Memoized via
# pkgmgrs_present.
detect::pkgmgr() {
  local first
  first=$(detect::pkgmgrs_present | command head -1)
  echo "${first:-unknown}"
}

# 0 if Homebrew is callable. brew itself refuses sudo by design, so
# presence = usable.
detect::has_brew() { detect::has_cmd brew; }

# 0 if flatpak is callable AND at least one remote is configured.
# A flatpak install without a remote has nothing to pull from.
detect::has_flatpak() {
  if [[ ${__DETECT_CACHE[has_flatpak]+set} == set ]]; then
    [[ ${__DETECT_CACHE[has_flatpak]} == 1 ]]
    return
  fi
  local result=0
  if detect::has_cmd flatpak; then
    local remotes
    remotes=$(detect::_run flatpak remotes --columns=name 2>/dev/null || true)
    [[ -n $remotes ]] && result=1
  fi
  __DETECT_CACHE[has_flatpak]=$result
  [[ $result == 1 ]]
}

# 0 if snap is callable AND snapd responds. The CLI alone is useless
# if snapd isn't running (common on minimal containers / distros where
# snap was installed but the socket is down).
detect::has_snap() {
  if [[ ${__DETECT_CACHE[has_snap]+set} == set ]]; then
    [[ ${__DETECT_CACHE[has_snap]} == 1 ]]
    return
  fi
  local result=0
  if detect::has_cmd snap && detect::_run snap version >/dev/null 2>&1; then
    result=1
  fi
  __DETECT_CACHE[has_snap]=$result
  [[ $result == 1 ]]
}

# 0 if nix is callable via either the legacy nix-env or the newer nix CLI.
detect::has_nix() {
  detect::has_cmd nix-env || detect::has_cmd nix
}

# Language-scoped package managers (design §3.10.4). Presence only —
# detailed "is this usable here" checks (writable bin dir, $GOBIN set,
# etc.) can tighten later if the resolver needs these as fallbacks.
# Currently none are default candidates; they're probed so `report_json`
# can surface what's available for user-added candidate entries.
detect::has_npm_global() { detect::has_cmd npm; }
detect::has_pip_user()   { detect::has_cmd pip3 || detect::has_cmd pip; }
detect::has_uv_tool()    { detect::has_cmd uv; }
detect::has_pipx()       { detect::has_cmd pipx; }
detect::has_cargo()      { detect::has_cmd cargo; }
detect::has_go_install() { detect::has_cmd go; }

#------------------------------------------------------------------------------
# Family-consistency cross-check (capability-driven, name as sanity check)
#------------------------------------------------------------------------------
#
# Data table — not a router. Consulted ONLY by detect::family_consistency
# to diagnose mismatch between what /etc/os-release claims and what's
# actually installed. Never picks a package manager.
declare -gA __DETECT_FAMILY_EXPECTED=(
  [debian]="apt"
  [rhel]="dnf rpm-ostree"
  [suse]="zypper transactional-update"
  [arch]="pacman"
  [alpine]="apk"
)

# Echoes consistent | inconsistent | unknown.
#   consistent   — declared family has an expected pkgmgr on the host
#   inconsistent — pkgmgrs don't match family expectations, or OS kernel
#                  disagrees with family (e.g. Darwin kernel + debian family)
#   unknown      — DETECTED_FAMILY is unknown, so nothing to check against
#
# Logs a warning on inconsistency but never blocks. Callers treat the
# result as diagnostic signal to surface in the report, not as routing.
detect::family_consistency() {
  detect::identity
  if [[ -z $DETECTED_FAMILY || $DETECTED_FAMILY == unknown ]]; then
    echo unknown
    return 0
  fi
  local expected=${__DETECT_FAMILY_EXPECTED[$DETECTED_FAMILY]:-}
  if [[ -z $expected ]]; then
    echo unknown
    return 0
  fi

  # Kernel/family sanity: all entries in __DETECT_FAMILY_EXPECTED are
  # Linux families. Darwin + any of these is inconsistent by definition.
  if [[ $(detect::uname_s) != Linux ]]; then
    echo inconsistent
    return 0
  fi

  local present=" $(detect::pkgmgrs_present | command tr '\n' ' ')"
  local mgr
  for mgr in $expected; do
    if [[ $present == *" $mgr "* ]]; then
      echo consistent
      return 0
    fi
  done
  echo inconsistent
}

#==============================================================================
# Section 3 (partial) — Version utilities
#==============================================================================

# Normalize a raw package version string to bare X.Y.Z[.W].
# Strips:
#   - Epoch prefix:           "1:2.34.1"      -> "2.34.1"
#   - Debian packaging:       "2.0.11-1ubuntu1" -> "2.0.11"
#   - RPM packaging:          "2.0.11-3.fc39"   -> "2.0.11"
#   - Pre-release markers:    "2.0.11~rc1"      -> "2.0.11"
#                             "2.0.11-beta3"    -> "2.0.11"
#   - Trailing non-digit tail: "2.0.11+build4"  -> "2.0.11"
#
# Does NOT implement SemVer pre-release ordering. Substitute
# detect::_version_compare for a full-semver port if that becomes necessary
# (see projects/dotfiles/plans/bootstrap-detection-plan §Decisions #3).
detect::_version_normalize() {
  local v=$1
  # Strip epoch.
  v=${v#*:}
  # Cut at the first non-version character: anything that's not a digit or dot.
  v=${v%%[!0-9.]*}
  # Trim trailing dot (happens when the input was "2.0.")
  v=${v%.}
  echo "$v"
}

# Compare two normalized version strings component by component.
# Echoes -1 / 0 / 1 and returns the same magnitude (0, 1, 2) as exit code
# for shell convenience — exit 0 on equal, nonzero otherwise.
# Missing trailing components are treated as 0 ("2.0" == "2.0.0").
detect::_version_compare() {
  local a=$1 b=$2
  local -a xs ys
  IFS=. read -ra xs <<<"$a"
  IFS=. read -ra ys <<<"$b"
  local n=${#xs[@]}
  (( ${#ys[@]} > n )) && n=${#ys[@]}
  local i x y
  for ((i = 0; i < n; i++)); do
    x=${xs[i]:-0}
    y=${ys[i]:-0}
    # Defensively coerce non-numeric components to 0 — normalize() should
    # have stripped them, but a belt-and-suspenders for hand-fed input.
    [[ $x =~ ^[0-9]+$ ]] || x=0
    [[ $y =~ ^[0-9]+$ ]] || y=0
    if (( x < y )); then echo -1; return 1; fi
    if (( x > y )); then echo 1;  return 1; fi
  done
  echo 0
  return 0
}

#==============================================================================
# Section 4 — Diagnostics (partial)
#==============================================================================

# Clear memoization caches + identity state. Intended for tests that swap
# OS_RELEASE_PATH or the _* indirection points between calls.
detect::reset() {
  __DETECT_CACHE=()
  DETECTED_ID=""
  DETECTED_ID_LIKE=""
  DETECTED_VERSION_ID=""
  DETECTED_VARIANT_ID=""
  DETECTED_NAME=""
  DETECTED_FAMILY=""
}

# Falsifiability guard per design §5.5: the library must not be invoked
# via sudo during sniffing. Running as actual root is FINE (container
# bootstrap scenarios); only the sudo-escalation path is rejected, since
# a sudo'd library would pick up root-scoped file permissions and mask
# real unprivileged-user probe failures.
#
# CI test: `sudo -n -u nobody bash -c '. detect-distro.sh; detect::summary'`
# must succeed. If it fails, we've regressed.
detect::_assert_no_sudo() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
  if [[ -n ${SUDO_USER:-} ]]; then
    echo "detect[error]: library must not be invoked via sudo during sniffing phase" >&2
    return 1
  fi
  return 0
}
