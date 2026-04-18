#!/bin/sh
# install.sh — curl-pipe bootstrap for uhop/dotfiles.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/uhop/dotfiles/main/install.sh | sh
#
# For unattended / CI use, pass --yes to skip all confirmations:
#   curl -fsSL https://raw.githubusercontent.com/uhop/dotfiles/main/install.sh | sh -s -- --yes
#
# This is a zero-setup entry point: assumes NOTHING is present locally other
# than a POSIX shell, either an existing sudo-capable account on Linux or a
# local admin account on macOS. Installs OS prereqs, Homebrew, chezmoi, then
# runs `chezmoi init --apply uhop/dotfiles`.
#
# For existing operator → remote provisioning, prefer `bootstrap-dotfiles
# <host>` from your already-set-up box. This script is for the "bootstrap the
# FIRST box" case.

set -eu

# ------------------------------------------------------------------------------
# Args
# ------------------------------------------------------------------------------
YES=0
REPO=uhop/dotfiles
BRANCH=main

while [ $# -gt 0 ]; do
  case $1 in
    -y|--yes)    YES=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --repo)      REPO=$2; shift ;;
    --branch)    BRANCH=$2; shift ;;
    *)           echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Colors — only on a real terminal.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$(printf '\033[1m'); RESET=$(printf '\033[0m')
  GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
  BOLD=; RESET=; GREEN=; YELLOW=; RED=
fi

step()  { printf '\n%s==> %s%s\n' "$BOLD$GREEN" "$*" "$RESET"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '%sWARNING:%s %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2; }
die()   { printf '%sERROR:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; exit 1; }

confirm() {
  if [ "$YES" -eq 1 ]; then return 0; fi
  prompt="$1 [y/N] "
  if [ -r /dev/tty ]; then
    printf '%s' "$prompt" > /dev/tty
    read -r reply < /dev/tty
  else
    die "no TTY for prompt; re-run with --yes to proceed non-interactively"
  fi
  case $reply in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Banner hint from /etc/os-release. Purely cosmetic — routing below is
# capability-driven (has_cmd apt-get / dnf / pacman / zypper / apk), not
# name-driven. Mirrors the detect:: library's §3 principle that pkgmgr
# presence drives behavior; distro name is a cross-check, never a router.
read_os_hint() {
  if [ "$(uname -s)" = Darwin ]; then
    echo "macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
  elif [ -r /etc/os-release ]; then
    ( . /etc/os-release 2>/dev/null
      echo "${PRETTY_NAME:-${NAME:-${ID:-unknown}} ${VERSION_ID:-}}"
    )
  else
    echo "unknown"
  fi
}

# ------------------------------------------------------------------------------
# Banner + platform detection
# ------------------------------------------------------------------------------
step "uhop/dotfiles bootstrap"
info "platform: $(read_os_hint) ($(uname -s) $(uname -m))"
info "repo:     $REPO @ $BRANCH"
info "mode:     $([ "$YES" -eq 1 ] && echo unattended || echo interactive)"

if [ "$YES" -eq 0 ] && [ ! -r /dev/tty ]; then
  die "no TTY for confirmation prompts; re-run with --yes:
    curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/install.sh | sh -s -- --yes"
fi

# ------------------------------------------------------------------------------
# Preflight: install OS prereqs (curl, git, build tools, bash-4)
#
# Routing is capability-driven. We probe for the package manager binary on
# $PATH rather than matching /etc/os-release ID — same principle as the
# detect:: library (see project_detect_capability_driven). Handles every
# Ubuntu/Debian/Fedora/Arch/SUSE derivative without needing a match list.
# macOS is the exception: we probe via `uname -s` because `brew` isn't
# installed yet, so has_cmd brew is false at this point by design.
# ------------------------------------------------------------------------------
step "preflight: checking base prerequisites"

MISSING=""
for tool in curl git; do
  has_cmd "$tool" || MISSING="$MISSING $tool"
done
# Require bash >= 4 for the detection library deployed later by chezmoi.
BASH_V=$(bash -c 'echo "${BASH_VERSINFO[0]:-0}"' 2>/dev/null || echo 0)
if [ "$BASH_V" -lt 4 ]; then
  MISSING="$MISSING bash"
fi

if [ -n "$MISSING" ]; then
  info "missing:$MISSING"
  if [ "$(uname -s)" = Darwin ]; then
    info "macOS: curl + git ship with the base system; bash will be installed via brew below."
    # curl + git are in base macOS; bash is 3.2 here but brew will install bash-4.
  elif has_cmd apt-get; then
    confirm "install via 'sudo apt install -y$MISSING build-essential file' ?" \
      || die "aborted by user"
    sudo apt-get update -q
    # shellcheck disable=SC2086
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING build-essential file
  elif has_cmd dnf; then
    confirm "install via 'sudo dnf install -y$MISSING gcc gcc-c++ make file' ?" \
      || die "aborted by user"
    # shellcheck disable=SC2086
    sudo dnf install -y $MISSING gcc gcc-c++ make file
  elif has_cmd pacman; then
    confirm "install via 'sudo pacman -S --needed$MISSING base-devel' ?" \
      || die "aborted by user"
    # shellcheck disable=SC2086
    sudo pacman -S --needed --noconfirm $MISSING base-devel
  elif has_cmd zypper; then
    confirm "install via 'sudo zypper install -y$MISSING gcc gcc-c++ make' ?" \
      || die "aborted by user"
    # shellcheck disable=SC2086
    sudo zypper install -y $MISSING gcc gcc-c++ make
  elif has_cmd apk; then
    die "Alpine uses musl libc; Homebrew is not supported on musl. See:
  https://github.com/$REPO/wiki/Distro-Compatibility#unsupported"
  else
    die "no known package manager found on \$PATH; install these manually and re-run:$MISSING
See: https://github.com/$REPO/wiki/Setting-Up-a-New-Machine"
  fi
else
  info "all base prereqs present"
fi

# ------------------------------------------------------------------------------
# Homebrew
# ------------------------------------------------------------------------------
if ! has_cmd brew; then
  step "Homebrew not found"
  if [ "$(uname -s)" = Darwin ]; then
    # Xcode CLT is a prereq of Homebrew on macOS. Trigger the installer if needed.
    if ! xcode-select -p >/dev/null 2>&1; then
      confirm "install Xcode Command Line Tools (interactive GUI prompt)?" \
        || die "aborted by user"
      xcode-select --install || true
      info "complete the Xcode CLT install dialog, then press ENTER here"
      if [ "$YES" -eq 0 ] && [ -r /dev/tty ]; then
        read -r _ < /dev/tty || true
      fi
    fi
  fi
  confirm "install Homebrew?" || die "aborted by user"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Activate brew in this shell so subsequent steps see `brew` and its tools.
  for brew_prefix in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do
    if [ -x "$brew_prefix/bin/brew" ]; then
      eval "$("$brew_prefix/bin/brew" shellenv)"
      break
    fi
  done
fi

# On macOS, ensure we have bash >= 4 (default /bin/bash is 3.2).
if [ "$(uname -s)" = Darwin ]; then
  if ! has_cmd bash || [ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ]; then
    step "installing modern bash via Homebrew (macOS default is 3.2)"
    brew install bash
  fi
fi

# ------------------------------------------------------------------------------
# chezmoi
# ------------------------------------------------------------------------------
if ! has_cmd chezmoi; then
  step "installing chezmoi"
  # Official chezmoi installer (same one used in bootstrap-dotfiles remote flow).
  mkdir -p "$HOME/.local/bin"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"
fi

info "chezmoi: $(chezmoi --version | head -1)"

# ------------------------------------------------------------------------------
# Apply dotfiles
# ------------------------------------------------------------------------------
step "chezmoi init --apply $REPO"
info "this pulls the dotfiles, sniffs the host with the detection library,"
info "installs system + brew packages, and wires up your shell / editors / tmux."

CHEZMOI_INIT_FLAGS="--apply"
if [ "$YES" -eq 1 ]; then
  CHEZMOI_INIT_FLAGS="$CHEZMOI_INIT_FLAGS --no-tty --promptDefaults"
fi
if [ "$BRANCH" != main ]; then
  CHEZMOI_INIT_FLAGS="$CHEZMOI_INIT_FLAGS --branch $BRANCH"
fi

confirm "proceed with apply? (installs system packages, can take several minutes)" \
  || die "aborted by user"

# shellcheck disable=SC2086
chezmoi init $CHEZMOI_INIT_FLAGS "$REPO"

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
step "bootstrap complete"
info "Next steps:"
info "  - open a new shell (or 'exec bash -l') to pick up PATH + bashrc"
info "  - deploy secrets if this is an operator box: jot-deploy <prefix>"
info "  - wiki: https://github.com/$REPO/wiki/Setting-Up-a-New-Machine"
