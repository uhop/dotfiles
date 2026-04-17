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
