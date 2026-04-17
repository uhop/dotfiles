# detect-distro.sh — bootstrap detection library.
#
# Single source of truth for identity + capability detection. Consumed by
# bootstrap-dotfiles, .chezmoi.toml.tmpl (via output + includeTemplate),
# and run_onchange_* scripts (via template inline). See
# dev-docs/bootstrap-detection-design.md for the full design; this file
# is the implementation.
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
#
# systemd-detect-virt -c signals via EXIT CODE, not output. It prints the
# container type and exits 0 inside a container; it prints "none" and exits
# 1 outside one. An earlier version of this probe tested for non-empty
# output, which misfired on every host with systemd installed because "none"
# is non-empty.
detect::is_container() {
  if [[ ${__DETECT_CACHE[is_container]+set} == set ]]; then
    [[ ${__DETECT_CACHE[is_container]} == 1 ]]
    return
  fi
  local result=0
  if [[ -e $DETECT_DOCKERENV ]] || [[ -n ${container:-} ]]; then
    result=1
  elif detect::has_cmd systemd-detect-virt \
    && detect::_run systemd-detect-virt -c >/dev/null 2>&1; then
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
# Section 3 — Package resolution
#==============================================================================
#
# Package managers expose themselves through a registry (detect::mgr_register)
# and four single-shot probes (pkg_avail / pkg_has / pkg_version / pkg_meets).
# Bulk variants, warmup, and the candidate-resolver sit on top of these in
# follow-up commits.

#------------------------------------------------------------------------------
# Version utilities
#------------------------------------------------------------------------------

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

#------------------------------------------------------------------------------
# Manager registry
#------------------------------------------------------------------------------
#
# Per-manager command templates, keyed by canonical manager name. Each
# template is a shell snippet with `{pkg}` as the single substitution
# point; the runner substitutes the package name and pipes the result to
# `bash -c`, so templates may use pipes, redirects, awk/grep, etc.
#
# Three axes today:
#   avail   — "<pkg> is in the manager's index?"    (exit 0 = yes)
#   has     — "<pkg> is installed via this manager?" (exit 0 = yes)
#   version — print the raw version string to stdout (may include distro
#             packaging tail — detect::_version_normalize handles that).
#
# Bulk variants + install templates join in a follow-up commit.

declare -gA __DETECT_MGR_AVAIL=()
declare -gA __DETECT_MGR_HAS=()
declare -gA __DETECT_MGR_VERSION=()
declare -gA __DETECT_MGR_INSTALL=()
declare -gA __DETECT_MGR_AVAIL_BULK=()

# Per-(mgr,pkg) availability cache populated by pkg_avail_bulk / warmup.
# Consulted by pkg_avail before firing the single-pkg template, so a warmup
# pass can turn N subprocess probes into 1 bulk call per manager
# (design §3.6.1–3.6.2).
declare -gA __DETECT_PKG_AVAIL_CACHE=()

# Substitute every `{pkg}` in the template with the given package name.
detect::_subst_pkg() {
  local tmpl=$1 pkg=$2
  printf '%s' "${tmpl//\{pkg\}/$pkg}"
}

# Substitute every `{pkgs}` in the template with the (space-joined)
# package list from the remaining args.
detect::_subst_pkgs() {
  local tmpl=$1
  shift
  local pkgs="$*"
  printf '%s' "${tmpl//\{pkgs\}/$pkgs}"
}

# Run a templated shell command through the test-monkey-patchable `_run`
# indirection. Templates are passed to `bash -c` so they may contain pipes,
# awk scripts, etc. Callers get the command's exit code and stdout.
detect::_run_tmpl() {
  local tmpl=$1 pkg=$2
  local cmd
  cmd=$(detect::_subst_pkg "$tmpl" "$pkg")
  detect::_run bash -c "$cmd"
}

# Register a manager's command templates. Positional arguments:
#   mgr      — canonical name (apt, dnf, ...).
#   avail    — "in the index?" template (uses `{pkg}`). Empty string means
#              the manager has no meaningful index query — pkg_avail returns
#              false.
#   has      — "installed?" template (`{pkg}`). Empty = pkg_has returns false.
#   version  — "what version?" template (`{pkg}`). Empty = pkg_version
#              returns empty.
#   install  — "install these packages" template. Uses `{pkgs}` (plural).
#              Empty = pkg_install returns 1.
#
# Consumers may re-call this to override defaults (e.g. swapping apt-cache
# for aptitude) before probing.
detect::mgr_register() {
  local mgr=$1 avail=${2:-} has=${3:-} version=${4:-} install=${5:-}
  __DETECT_MGR_AVAIL[$mgr]=$avail
  __DETECT_MGR_HAS[$mgr]=$has
  __DETECT_MGR_VERSION[$mgr]=$version
  __DETECT_MGR_INSTALL[$mgr]=$install
}

# Register a bulk-availability template for <mgr>. The template uses
# `{pkgs}` (plural) and must print the names of the packages that exist
# in the index — one per line — to stdout. Missing packages are inferred
# by absence, so the template can rely on apt-cache / dnf info / etc.
# silently dropping unknowns. Optional — managers without a bulk template
# fall back to single-pkg probes through the cache-miss path.
detect::mgr_register_avail_bulk() {
  local mgr=$1 tmpl=${2:-}
  __DETECT_MGR_AVAIL_BULK[$mgr]=$tmpl
}

#------------------------------------------------------------------------------
# Single-package probes
#------------------------------------------------------------------------------

# 0 if <pkg> is available in <mgr>'s index. Consults the warmup-populated
# __DETECT_PKG_AVAIL_CACHE first; falls back to the single-pkg avail
# template on cache miss.
detect::pkg_avail() {
  local mgr=$1 pkg=$2
  local key="$mgr:$pkg"
  if [[ ${__DETECT_PKG_AVAIL_CACHE[$key]+set} == set ]]; then
    [[ ${__DETECT_PKG_AVAIL_CACHE[$key]} == 1 ]]
    return
  fi
  local tmpl=${__DETECT_MGR_AVAIL[$mgr]:-}
  [[ -z $tmpl ]] && return 1
  detect::_run_tmpl "$tmpl" "$pkg" >/dev/null 2>&1
}

# Bulk-probe <pkg…> against <mgr>'s index via the registered
# avail_bulk template. Populates __DETECT_PKG_AVAIL_CACHE and echoes
# uniform `name<TAB>avail|missing` lines to stdout so callers can also
# consume the result directly. Returns 1 if <mgr> has no bulk template
# registered.
detect::pkg_avail_bulk() {
  local mgr=$1
  shift
  local tmpl=${__DETECT_MGR_AVAIL_BULK[$mgr]:-}
  [[ -z $tmpl ]] && return 1
  (( $# == 0 )) && return 0

  local cmd output
  cmd=$(detect::_subst_pkgs "$tmpl" "$@")
  output=$(detect::_run bash -c "$cmd" 2>/dev/null || true)

  local -A found=()
  local name
  while IFS= read -r name; do
    [[ -n $name ]] && found[$name]=1
  done <<<"$output"

  local pkg
  for pkg; do
    if [[ ${found[$pkg]:-0} == 1 ]]; then
      __DETECT_PKG_AVAIL_CACHE["$mgr:$pkg"]=1
      printf '%s\tavail\n' "$pkg"
    else
      __DETECT_PKG_AVAIL_CACHE["$mgr:$pkg"]=0
      printf '%s\tmissing\n' "$pkg"
    fi
  done
  return 0
}

# 0 if <pkg> is currently installed via <mgr>.
detect::pkg_has() {
  local mgr=$1 pkg=$2
  local tmpl=${__DETECT_MGR_HAS[$mgr]:-}
  [[ -z $tmpl ]] && return 1
  detect::_run_tmpl "$tmpl" "$pkg" >/dev/null 2>&1
}

# Echoes the raw version string <mgr> reports for <pkg>. Empty if the
# manager has no version template or the command fails. Output may include
# distro-packaging tails (e.g. "2.34.1-1ubuntu1.9") — pass through
# detect::_version_normalize before comparison.
detect::pkg_version() {
  local mgr=$1 pkg=$2
  local tmpl=${__DETECT_MGR_VERSION[$mgr]:-}
  [[ -z $tmpl ]] && return 0
  detect::_run_tmpl "$tmpl" "$pkg" 2>/dev/null || true
}

# Install one or more packages via <mgr>. Returns the install command's
# exit status. Empty package list short-circuits to success (nothing to do).
# Unknown/unregistered manager → return 1. Most templates begin with `sudo`
# and will prompt on the TTY.
detect::pkg_install() {
  local mgr=$1
  shift
  local tmpl=${__DETECT_MGR_INSTALL[$mgr]:-}
  [[ -z $tmpl ]] && return 1
  (( $# == 0 )) && return 0
  local cmd
  cmd=$(detect::_subst_pkgs "$tmpl" "$@")
  detect::_run bash -c "$cmd"
}

# 0 if <mgr> has <pkg> at a normalized version >= <min>.
# An empty <min> short-circuits to pkg_avail (any version acceptable).
detect::pkg_meets() {
  local mgr=$1 pkg=$2 min=${3:-}
  detect::pkg_avail "$mgr" "$pkg" || return 1
  [[ -z $min ]] && return 0
  local raw
  raw=$(detect::pkg_version "$mgr" "$pkg")
  [[ -z $raw ]] && return 1
  local norm
  norm=$(detect::_version_normalize "$raw")
  [[ -z $norm ]] && return 1
  local cmp
  cmp=$(detect::_version_compare "$norm" "$min" 2>/dev/null || true)
  [[ $cmp == 0 || $cmp == 1 ]]
}

#------------------------------------------------------------------------------
# Default manager registrations
#------------------------------------------------------------------------------
#
# Shell snippets — callers should think in shell quoting terms. The `\$`
# sequences (e.g. `\${Status}`) survive storage through single quotes here
# and are de-escaped by the inner `bash -c` at call time, so the wrapped
# tool sees a literal `${Status}` field reference.
#
# Templates below are first-pass; the LXD matrix will refine anything that
# misbehaves on real hosts before PR 3 lights up the resolver end-to-end.

# apt — dpkg-query for installed state, apt-cache for the index.
detect::mgr_register apt \
  'apt-cache show {pkg}' \
  'dpkg-query -W -f=\${Status} {pkg} 2>/dev/null | grep -q "ok installed"' \
  'dpkg-query -W -f=\${Version} {pkg}' \
  'sudo apt-get install -y {pkgs}'

# dnf / rpm family.
detect::mgr_register dnf \
  'dnf info -q {pkg}' \
  'rpm -q {pkg}' \
  'rpm -q --queryformat "%{VERSION}" {pkg}' \
  'sudo dnf install -y {pkgs}'

# zypper shares rpm for installed state + versions.
detect::mgr_register zypper \
  'zypper -n info {pkg}' \
  'rpm -q {pkg}' \
  'rpm -q --queryformat "%{VERSION}" {pkg}' \
  'sudo zypper -n install {pkgs}'

# pacman — -Si probes the index, -Qq the local db.
detect::mgr_register pacman \
  'pacman -Si {pkg}' \
  'pacman -Qq {pkg}' \
  'pacman -Q {pkg} | awk "{ print \$2 }"' \
  'sudo pacman -S --noconfirm --needed {pkgs}'

# apk — `apk info -e` for installed, `apk search -e` for the index.
detect::mgr_register apk \
  'apk search -e {pkg} | grep -q .' \
  'apk info -e {pkg}' \
  'apk info -ws {pkg} 2>/dev/null | awk "/-/ { print \$0; exit }"' \
  'sudo apk add {pkgs}'

# brew — formula-only for now; casks are an orthogonal axis handled later.
detect::mgr_register brew \
  'brew info --formula {pkg}' \
  'brew list --formula --versions {pkg}' \
  'brew list --formula --versions {pkg} | awk "{ print \$2 }"' \
  'brew install {pkgs}'

# rpm-ostree — immutable: no index query of its own; installed state via rpm.
detect::mgr_register rpm-ostree \
  '' \
  'rpm -q {pkg}' \
  'rpm -q --queryformat "%{VERSION}" {pkg}' \
  'sudo rpm-ostree install -A {pkgs}'

# transactional-update (MicroOS) — shares zypper index + rpm db.
detect::mgr_register transactional-update \
  'zypper -n info {pkg}' \
  'rpm -q {pkg}' \
  'rpm -q --queryformat "%{VERSION}" {pkg}' \
  'sudo transactional-update -n pkg install {pkgs}'

# Bulk-availability templates — enable warmup to batch pkg_avail probes.
# Only apt + brew are registered as defaults today; they've been smoke-tested
# against real hosts (Ubuntu 25.10 + Homebrew on Linux). dnf / zypper /
# pacman / apk / rpm-ostree need LXD-matrix verification before their bulk
# templates can ship; consumers who want warmup on those managers register
# the templates themselves via detect::mgr_register_avail_bulk.
detect::mgr_register_avail_bulk apt \
  'apt-cache show {pkgs} 2>/dev/null | awk "/^Package:/ { print \$2 }"'
detect::mgr_register_avail_bulk brew \
  'brew info --formula {pkgs} 2>/dev/null | awk "/^==> [a-z]/ { gsub(/:/, \"\", \$2); print \$2 }"'

#------------------------------------------------------------------------------
# Candidate resolution
#------------------------------------------------------------------------------
#
# Logical-capability → (manager, package_name[, min_version]) resolution.
# The candidate table lives in detect-packages.sh (sourced separately by
# consumers); this file owns the lookup logic only.

declare -gA __DETECT_CANDIDATES=()

# Managers disabled by detect::apply_overrides. Populated per the §3.8
# decision table (e.g. dnf is disabled on Silverblue in favor of
# rpm-ostree). Consumers must call apply_overrides once after identity
# probes stabilize, or entries stay unset (no overrides applied).
declare -gA __DETECT_MGR_DISABLED=()

# Echoes newline-separated list of manager names the resolver should
# consider. Starts with sniffed primary system managers (detect::pkgmgrs_present,
# which already includes brew and nix via __DETECT_MGR_SNIFFS). Entries
# disabled by apply_overrides are filtered out. Snap is opt-in via
# DETECT_ALLOW_SNAP=1 so CLI tooling doesn't accidentally route through
# snap unless the user has said so (design §3.10.2 + plan #4).
detect::active_managers() {
  local mgr
  while IFS= read -r mgr; do
    [[ -z $mgr ]] && continue
    [[ ${__DETECT_MGR_DISABLED[$mgr]:-0} == 1 ]] && continue
    echo "$mgr"
  done < <(detect::pkgmgrs_present)
  if detect::has_snap && [[ ${DETECT_ALLOW_SNAP:-0} == 1 ]]; then
    [[ ${__DETECT_MGR_DISABLED[snap]:-0} == 1 ]] || echo snap
  fi
}

# Resolve a logical capability to a concrete (manager, name) pair.
#
# On success: echoes "<mgr> <name>" and returns 0.
# On no match: echoes nothing and returns 1.
#
# Candidate entries are space/newline-separated "mgr:name[:min_version]"
# tuples. Blank lines and lines starting with `#` are ignored.
#
# Filters applied in order:
#   1. Manager must be in detect::active_managers.
#   2. Manager must not appear in $DETECT_OPT_OUT (space-separated).
#   3. Package must pass pkg_meets (or pkg_avail when no min_version given).
detect::pkg_resolve() {
  local capability=$1
  local candidates=${__DETECT_CANDIDATES[$capability]:-}
  [[ -z $candidates ]] && return 1

  local active
  active=" $(detect::active_managers | command tr '\n' ' ')"
  local opt_out=" ${DETECT_OPT_OUT:-} "

  local line entry mgr name rest minver
  while IFS= read -r line; do
    # Strip leading/trailing whitespace.
    entry=${line#"${line%%[![:space:]]*}"}
    entry=${entry%"${entry##*[![:space:]]}"}
    [[ -z $entry || $entry == \#* ]] && continue

    mgr=${entry%%:*}
    rest=${entry#*:}
    if [[ $rest == *:* ]]; then
      name=${rest%%:*}
      minver=${rest#*:}
    else
      name=$rest
      minver=""
    fi

    [[ $active  == *" $mgr "* ]] || continue
    [[ $opt_out == *" $mgr "* ]] && continue

    if [[ -n $minver ]]; then
      detect::pkg_meets "$mgr" "$name" "$minver" || continue
    else
      detect::pkg_avail "$mgr" "$name" || continue
    fi
    echo "$mgr $name"
    return 0
  done <<<"$candidates"
  return 1
}

#------------------------------------------------------------------------------
# Orchestrator: resolve + batched install per manager
#------------------------------------------------------------------------------

# Ensure one or more logical capabilities are installed. For each
# capability:
#   1. Resolve it to a (mgr, pkg) pair via detect::pkg_resolve.
#   2. Skip if pkg_has already reports it installed.
#   3. Otherwise accumulate into a per-manager bucket.
# Then issue one install call per manager (batched per design §3.6.3).
#
# Flags:
#   --dry-run   Print what would run; do not execute.
#   --strict    Return 2 if any capability is unresolved (default: warn
#               and continue with the rest).
#
# Exit codes:
#   0  all capabilities resolved and installed/skipped successfully
#   1  one or more install commands failed
#   2  one or more capabilities unresolved (only with --strict)
#  64  unknown flag
#
# Progress lines go to stderr with a `detect[...]` tag so callers can
# filter / capture cleanly.
detect::pkg_ensure() {
  local dry_run=0 strict=0
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --strict)  strict=1;  shift ;;
      --) shift; break ;;
      -*)
        echo "detect[error]: pkg_ensure: unknown flag: $1" >&2
        return 64
        ;;
      *) break ;;
    esac
  done
  (( $# == 0 )) && return 0

  local -A buckets=()
  local -a unresolved=()

  local cap result mgr name
  for cap; do
    if ! result=$(detect::pkg_resolve "$cap"); then
      unresolved+=("$cap")
      echo "detect[warn]: no candidate resolved for '$cap'" >&2
      continue
    fi
    read -r mgr name <<<"$result"
    if detect::pkg_has "$mgr" "$name"; then
      echo "detect[skip] $cap: $mgr/$name (already installed)" >&2
      continue
    fi
    buckets[$mgr]="${buckets[$mgr]:+${buckets[$mgr]} }$name"
  done

  local rc=0 tmpl cmd pkgs
  for mgr in "${!buckets[@]}"; do
    pkgs=${buckets[$mgr]}
    tmpl=${__DETECT_MGR_INSTALL[$mgr]:-}
    if [[ -z $tmpl ]]; then
      echo "detect[error]: $mgr has no install template — cannot install: $pkgs" >&2
      rc=1
      continue
    fi
    # shellcheck disable=SC2086
    cmd=$(detect::_subst_pkgs "$tmpl" $pkgs)
    echo "detect[install] $mgr: $pkgs" >&2
    if (( dry_run )); then
      echo "[dry-run] $cmd" >&2
    else
      if ! detect::_run bash -c "$cmd"; then
        rc=1
        echo "detect[error]: $mgr install failed: $cmd" >&2
      fi
    fi
  done

  if (( ${#unresolved[@]} > 0 && strict )); then
    return 2
  fi
  return "$rc"
}

#------------------------------------------------------------------------------
# Warmup — bulk-probe all candidate packages in one pass per manager
#------------------------------------------------------------------------------

# Walk __DETECT_CANDIDATES, group every referenced package by manager,
# and fire one pkg_avail_bulk per active manager that has a bulk template
# registered. After this returns, pkg_resolve / pkg_ensure can run
# without spawning per-package subprocesses — the cache populated here
# answers `pkg_avail` directly. Managers without a bulk template skip
# warmup and still work via single-pkg probes (design §3.6.2).
detect::warmup() {
  local -A by_mgr=()
  local cap line entry mgr rest name

  for cap in "${!__DETECT_CANDIDATES[@]}"; do
    while IFS= read -r line; do
      entry=${line#"${line%%[![:space:]]*}"}
      entry=${entry%"${entry##*[![:space:]]}"}
      [[ -z $entry || $entry == \#* ]] && continue
      mgr=${entry%%:*}
      rest=${entry#*:}
      if [[ $rest == *:* ]]; then
        name=${rest%%:*}
      else
        name=$rest
      fi
      by_mgr[$mgr]="${by_mgr[$mgr]:+${by_mgr[$mgr]} }$name"
    done <<<"${__DETECT_CANDIDATES[$cap]}"
  done

  for mgr in "${!by_mgr[@]}"; do
    [[ -z ${__DETECT_MGR_AVAIL_BULK[$mgr]:-} ]] && continue

    # Dedup package names within each manager (two capabilities may name
    # the same pkg; no point querying twice).
    local -A seen=()
    local -a uniq=()
    local pkg
    for pkg in ${by_mgr[$mgr]}; do
      if [[ ${seen[$pkg]:-0} == 0 ]]; then
        uniq+=("$pkg")
        seen[$pkg]=1
      fi
    done
    # shellcheck disable=SC2086
    detect::pkg_avail_bulk "$mgr" "${uniq[@]}" >/dev/null
  done
  return 0
}

#------------------------------------------------------------------------------
# Decision-table overrides (design §3.8)
#------------------------------------------------------------------------------
#
# Where capability sniffing needs a nudge from the declared family — or
# where a consumer needs to know about an environmental constraint that
# can't be expressed purely through the resolver — we encode it here.
# apply_overrides is idempotent: calling it twice with the same detected
# state yields the same disabled-manager set. Consumers call it once
# after sourcing detect-distro.sh + detect-packages.sh, before any
# pkg_resolve / pkg_ensure calls.

# Disable managers that should be superseded on the current host, per
# the §3.8 decision table. Also emits a one-line warning for the
# "unknown family but pkgmgr detected" case (rule 5).
#
# Rules 3 and 4 (container/init and IPv6) don't change resolution — they
# expose themselves through the detect::should_* predicates below so
# consumer install scripts can branch on them.
detect::apply_overrides() {
  __DETECT_MGR_DISABLED=()
  detect::identity

  # Rule 1: rhel + immutable + rpm-ostree → dnf is off-limits.
  if [[ $DETECTED_FAMILY == rhel ]] \
    && detect::is_immutable \
    && detect::has_cmd rpm-ostree; then
    __DETECT_MGR_DISABLED[dnf]=1
    __DETECT_MGR_DISABLED[dnf5]=1
  fi

  # Rule 2: suse + immutable + transactional-update → zypper is off-limits.
  if [[ $DETECTED_FAMILY == suse ]] \
    && detect::is_immutable \
    && detect::has_cmd transactional-update; then
    __DETECT_MGR_DISABLED[zypper]=1
  fi

  # Rule 5: unknown family but a pkgmgr is present — proceed, warn once.
  local primary
  primary=$(detect::pkgmgr)
  if [[ $DETECTED_FAMILY == unknown && $primary != unknown ]]; then
    echo "detect[warn]: unknown family; proceeding with $primary (report if misbehaves)" >&2
  fi

  return 0
}

# Rule 3: consumer install scripts can skip systemd-unit steps when
# there's no systemd to talk to (containers without their own init).
detect::should_skip_systemd() {
  detect::is_container && [[ $(detect::init_system) == unknown ]]
}

# Rule 4: consumer scripts pulling over the network should force IPv4
# when no IPv6 route is available. Typical use: `curl $(detect::should_force_ipv4 && echo -4) ...`.
detect::should_force_ipv4() {
  ! detect::has_ipv6
}

#==============================================================================
# Section 4 — Diagnostics
#==============================================================================

# Print "yes" or "no" based on the exit status of the probe function passed
# in. Convenience wrapper for summary output.
detect::_yn() {
  if "$@"; then echo yes; else echo no; fi
}

# Escape a string for safe embedding inside JSON double-quotes. Handles the
# two characters that actually occur in probe output: backslash and quote.
# Control characters (< 0x20) are not expected in any of our fields — if
# they ever appear, json consumers will reject the output, which is the
# signal we'd want.
detect::_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Emit a JSON array of strings from the positional arguments. Empty argv
# yields `[]`.
detect::_json_arr() {
  printf '['
  local first=1 elem
  for elem; do
    if (( first )); then first=0
    else printf ', '
    fi
    printf '"%s"' "$(detect::_json_escape "$elem")"
  done
  printf ']'
}

# Multi-line human-readable report of all probed values. Consumed by
# bootstrap-dotfiles pre-flight (design §4.1); chezmoi reads report_json
# instead. No ANSI color — output is often captured by templates.
detect::summary() {
  detect::identity

  local pkgmgrs_str="" m
  while IFS= read -r m; do
    [[ -z $m ]] && continue
    pkgmgrs_str+="${pkgmgrs_str:+ }$m"
  done < <(detect::pkgmgrs_present)
  [[ -z $pkgmgrs_str ]] && pkgmgrs_str="(none)"

  local sudo_group
  sudo_group=$(detect::sudo_group)
  [[ -z $sudo_group ]] && sudo_group="(none)"

  local -a lang_enabled=()
  detect::has_npm_global  && lang_enabled+=(npm)
  detect::has_pip_user    && lang_enabled+=(pip)
  detect::has_uv_tool     && lang_enabled+=(uv)
  detect::has_pipx        && lang_enabled+=(pipx)
  detect::has_cargo       && lang_enabled+=(cargo)
  detect::has_go_install  && lang_enabled+=(go)
  local lang_str
  if (( ${#lang_enabled[@]} )); then
    lang_str="${lang_enabled[*]}"
  else
    lang_str="(none)"
  fi

  printf '%-20s %s\n' "Distro:"          "${DETECTED_ID:-unknown} ${DETECTED_VERSION_ID:-?} (${DETECTED_FAMILY} family)"
  [[ -n ${DETECTED_NAME:-} ]] && \
    printf '%-20s %s\n' "Pretty name:"   "$DETECTED_NAME"
  printf '%-20s %s\n' "Kernel:"          "$(detect::uname_s) $(detect::arch)"
  printf '%-20s %s\n' "Init:"            "$(detect::init_system)"
  printf '%-20s %s\n' "Pkgmgrs:"         "$pkgmgrs_str"
  printf '%-20s %s\n' "Primary pkgmgr:"  "$(detect::pkgmgr)"
  printf '%-20s %s\n' "Family check:"    "$(detect::family_consistency)"
  printf '%-20s %s\n' "Immutable FS:"    "$(detect::_yn detect::is_immutable)"
  printf '%-20s %s\n' "Container:"       "$(detect::_yn detect::is_container)"
  printf '%-20s %s\n' "WSL:"             "$(detect::_yn detect::is_wsl)"
  printf '%-20s %s\n' "IPv6:"            "$(detect::_yn detect::has_ipv6)"
  printf '%-20s %s\n' "Sudo group:"      "$sudo_group"
  printf '%-20s %s\n' "Sudo nopasswd:"   "$(detect::_yn detect::can_sudo_nopasswd)"
  printf '%-20s %s\n' "Brew:"            "$(detect::_yn detect::has_brew)"
  printf '%-20s %s\n' "Flatpak:"         "$(detect::_yn detect::has_flatpak)"
  printf '%-20s %s\n' "Snap:"            "$(detect::_yn detect::has_snap)"
  printf '%-20s %s\n' "Nix:"             "$(detect::_yn detect::has_nix)"
  printf '%-20s %s\n' "Lang pkgmgrs:"    "$lang_str"
}

# Full probe snapshot as a flat JSON object. Consumed by .chezmoi.toml.tmpl
# via chezmoi's `output` template function — keys map to `.detect.*` data
# keys in PR 2. Shape is intentionally flat; nested objects would complicate
# chezmoi template access.
#
# Probe values are captured into locals up front (in the current shell) so
# memoization writes aren't lost to command-substitution subshells.
detect::report_json() {
  detect::identity

  # Identity + capability values (strings).
  local pkgmgr_v family_v arch_v uname_v init_v cons_v sudo_group_v
  pkgmgr_v=$(detect::pkgmgr)
  family_v=${DETECTED_FAMILY:-unknown}
  arch_v=$(detect::arch)
  uname_v=$(detect::uname_s)
  init_v=$(detect::init_system)
  cons_v=$(detect::family_consistency)
  sudo_group_v=$(detect::sudo_group)

  # Bool probes — one call each, cache captured.
  local b_immutable b_container b_wsl b_ipv6 b_nopasswd
  local b_brew b_flatpak b_snap b_nix
  local b_npm b_pip b_uv b_pipx b_cargo b_go
  detect::is_immutable        && b_immutable=true || b_immutable=false
  detect::is_container        && b_container=true || b_container=false
  detect::is_wsl              && b_wsl=true       || b_wsl=false
  detect::has_ipv6            && b_ipv6=true      || b_ipv6=false
  detect::can_sudo_nopasswd   && b_nopasswd=true  || b_nopasswd=false
  detect::has_brew            && b_brew=true      || b_brew=false
  detect::has_flatpak         && b_flatpak=true   || b_flatpak=false
  detect::has_snap            && b_snap=true      || b_snap=false
  detect::has_nix             && b_nix=true       || b_nix=false
  detect::has_npm_global      && b_npm=true       || b_npm=false
  detect::has_pip_user        && b_pip=true       || b_pip=false
  detect::has_uv_tool         && b_uv=true        || b_uv=false
  detect::has_pipx            && b_pipx=true      || b_pipx=false
  detect::has_cargo           && b_cargo=true     || b_cargo=false
  detect::has_go_install      && b_go=true        || b_go=false

  # pkgmgrs_present → args list for _json_arr.
  local -a mgrs=()
  local line
  while IFS= read -r line; do
    [[ -n $line ]] && mgrs+=("$line")
  done < <(detect::pkgmgrs_present)

  printf '{\n'
  printf '  "pkgmgr": "%s",\n'            "$(detect::_json_escape "$pkgmgr_v")"
  printf '  "pkgmgrsPresent": %s,\n'      "$(detect::_json_arr ${mgrs[@]+"${mgrs[@]}"})"
  printf '  "family": "%s",\n'            "$(detect::_json_escape "$family_v")"
  printf '  "familyConsistency": "%s",\n' "$(detect::_json_escape "$cons_v")"
  printf '  "id": "%s",\n'                "$(detect::_json_escape "${DETECTED_ID:-}")"
  printf '  "idLike": "%s",\n'            "$(detect::_json_escape "${DETECTED_ID_LIKE:-}")"
  printf '  "versionId": "%s",\n'         "$(detect::_json_escape "${DETECTED_VERSION_ID:-}")"
  printf '  "name": "%s",\n'              "$(detect::_json_escape "${DETECTED_NAME:-}")"
  printf '  "arch": "%s",\n'              "$(detect::_json_escape "$arch_v")"
  printf '  "uname": "%s",\n'             "$(detect::_json_escape "$uname_v")"
  printf '  "initSystem": "%s",\n'        "$(detect::_json_escape "$init_v")"
  printf '  "isImmutable": %s,\n'         "$b_immutable"
  printf '  "isContainer": %s,\n'         "$b_container"
  printf '  "isWsl": %s,\n'               "$b_wsl"
  printf '  "hasIpv6": %s,\n'             "$b_ipv6"
  printf '  "sudoGroup": "%s",\n'         "$(detect::_json_escape "$sudo_group_v")"
  printf '  "canSudoNopasswd": %s,\n'     "$b_nopasswd"
  printf '  "hasBrew": %s,\n'             "$b_brew"
  printf '  "hasFlatpak": %s,\n'          "$b_flatpak"
  printf '  "hasSnap": %s,\n'             "$b_snap"
  printf '  "hasNix": %s,\n'              "$b_nix"
  printf '  "hasNpmGlobal": %s,\n'        "$b_npm"
  printf '  "hasPipUser": %s,\n'          "$b_pip"
  printf '  "hasUvTool": %s,\n'           "$b_uv"
  printf '  "hasPipx": %s,\n'             "$b_pipx"
  printf '  "hasCargo": %s,\n'            "$b_cargo"
  printf '  "hasGoInstall": %s\n'         "$b_go"
  printf '}\n'
}

# Clear memoization caches + identity state + applied overrides.
# Intended for tests that swap OS_RELEASE_PATH or the _* indirection
# points between calls. Consumers of the library should NOT call this
# during normal operation; it's an escape hatch for test harnesses.
detect::reset() {
  __DETECT_CACHE=()
  __DETECT_MGR_DISABLED=()
  __DETECT_PKG_AVAIL_CACHE=()
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
