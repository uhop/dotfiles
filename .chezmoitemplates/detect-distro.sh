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

# Memoization cache — keyed by probe name. `detect::reset` clears it.
declare -gA __DETECT_CACHE=()

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
# Order matters: more-specific forms (debian before generic linux) win.
detect::_derive_family() {
  local id=$1 id_like=$2
  local haystack=" $id $id_like "

  # Darwin doesn't ship os-release; identity() won't populate here.
  # Consumers check $(uname -s) separately.
  case "$haystack" in
    *" debian "*|*" ubuntu "*)  echo debian ;;
    *" rhel "*|*" fedora "*|*" centos "*)  echo rhel ;;
    *" suse "*|*" opensuse "*|*" opensuse-tumbleweed "*|*" opensuse-leap "*)  echo suse ;;
    *" arch "*|*" archlinux "*|*" manjaro "*)  echo arch ;;
    *" alpine "*)  echo alpine ;;
    *" amzn "*)  echo rhel ;;
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
# Diagnostics
#==============================================================================

# Clear memoization caches. Intended for tests that swap OS_RELEASE_PATH
# between calls.
detect::reset() {
  __DETECT_CACHE=()
  DETECTED_ID=""
  DETECTED_ID_LIKE=""
  DETECTED_VERSION_ID=""
  DETECTED_VARIANT_ID=""
  DETECTED_NAME=""
  DETECTED_FAMILY=""
}
