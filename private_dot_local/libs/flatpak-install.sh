# flatpak-install.sh — dispatch flatpak installs between --system and --user.
#
# Source via:
#   . ~/.local/libs/flatpak-install.sh
#
# Pure bash; no options.bash dependency. Safe to source multiple times.
# No side effects on sourcing — all behavior is function-local.
#
# Design reference: bootstrap-detection-design.md §3.10.1.1. When the
# broader detect:: library lands, these functions migrate under the
# detect::flatpak_* namespace; the logic stays the same.

# Path to the project-managed polkit rule that allows sudo/wheel members
# to run org.freedesktop.Flatpak.* without a password prompt over SSH.
# Deployed by run_onchange_after_install-flatpak-polkit.sh.tmpl.
FLATPAK_INSTALL_POLKIT_RULE=${FLATPAK_INSTALL_POLKIT_RULE:-/usr/local/share/polkit-1/rules.d/90-flatpak-ssh.rules}

# Default remote. flathub is the only remote the project configures today
# (run_onchange_before_install-packages.sh.tmpl); override per-call via the
# CLI's --remote or by passing a remote argument to ::install.
FLATPAK_INSTALL_REMOTE=${FLATPAK_INSTALL_REMOTE:-flathub}

# ---- Probes ----

# 0 if the managed polkit rule file is present.
flatpak_install::has_polkit_rule() {
  [ -f "$FLATPAK_INSTALL_POLKIT_RULE" ]
}

# 0 if the current user is a member of sudo or wheel. These are the groups
# the polkit rule authorizes; admin (macOS) is deliberately excluded — flatpak
# is Linux-only here.
flatpak_install::in_sudo_group() {
  groups "$(id -un)" | grep -qE '\b(sudo|wheel)\b'
}

# 0 if passwordless sudo works right now.
flatpak_install::can_sudo_nopasswd() {
  sudo -n true 2>/dev/null
}

# 0 if a --system install is viable without prompting the user for a password:
# either the polkit rule is deployed AND the user is in sudo/wheel, or
# passwordless sudo is available generally.
flatpak_install::can_system() {
  (flatpak_install::has_polkit_rule && flatpak_install::in_sudo_group) \
    || flatpak_install::can_sudo_nopasswd
}

# Echo the scope that currently holds the given ref: system | user | none.
# Checks --system first because it's the project default.
flatpak_install::scope_of() {
  local pkg=$1
  if flatpak info --system "$pkg" >/dev/null 2>&1; then
    echo system
  elif flatpak info --user "$pkg" >/dev/null 2>&1; then
    echo user
  else
    echo none
  fi
}

# Echo the scope the dispatcher would pick for a new install: system | user.
flatpak_install::chosen_scope() {
  if flatpak_install::can_system; then
    echo system
  else
    echo user
  fi
}

# 0 if a --system install must be wrapped in `sudo` (i.e., we are relying
# on passwordless sudo rather than the polkit rule). When this returns
# non-zero, plain `flatpak install --system` is expected to work because
# the polkit rule authorizes the current user to run Flatpak D-Bus
# actions without a password; over SSH, that path is the only one that
# works without an interactive polkit agent.
#
# Precondition: only meaningful when ::can_system is true.
flatpak_install::system_needs_sudo() {
  flatpak_install::has_polkit_rule && flatpak_install::in_sudo_group && return 1
  return 0
}

# 0 if the given remote is configured in the chosen scope (or any scope
# if called without a scope argument).
# Args: <remote> [system|user]
flatpak_install::has_remote() {
  local remote=$1 scope=${2:-}
  case "$scope" in
    system) flatpak remotes --system --columns=name 2>/dev/null | grep -Fxq "$remote" ;;
    user)   flatpak remotes --user   --columns=name 2>/dev/null | grep -Fxq "$remote" ;;
    *)      flatpak remotes          --columns=name 2>/dev/null | grep -Fxq "$remote" ;;
  esac
}
