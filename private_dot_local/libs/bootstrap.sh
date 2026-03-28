# Bootstrap file for options.bash utilities.
#
# Save as ~/.local/libs/bootstrap.sh and source from your scripts:
#   . ~/.local/libs/bootstrap.sh
#
# Auto-updates the library on each invocation (requires git).
# Sources core modules so scripts start with full functionality.

# auto-update
command -v git &> /dev/null && git -C ~/.local/share/libs/scripts pull --no-recurse-submodules > /dev/null || true

# core modules
. ~/.local/share/libs/scripts/ansi.sh
. ~/.local/share/libs/scripts/args.sh
. ~/.local/share/libs/scripts/args-version.sh
. ~/.local/share/libs/scripts/args-help.sh
. ~/.local/share/libs/scripts/args-completion.sh

# echo the first argument and run
echoRun() {
  ansi::out "${FG_CYAN}$@${RESET_ALL}"
  eval "$@"
}

echoRunBold() {
  ansi::out "${BOLD}${FG_CYAN}$@${RESET_ALL}"
  eval "$@"
}

# echo the command, run it, and capture stdout and/or stderr to files while still displaying them
# Usage: echoRunTee <stdout_file> <stderr_file> <command...>
# Pass /dev/null for a file if you don't want to capture that stream
# Returns: exit code of the command
echoRunTee() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2
  ansi::out "${FG_CYAN}$@${RESET_ALL}"
  eval "$@" > >(tee "$stdout_file") 2> >(tee "$stderr_file" >&2)
}

# set up doas
command -v doas &>/dev/null && [ -f /etc/doas.conf ] && alias sudo='doas' || true
