# include options.bash
command -v git &> /dev/null && git -C ~/.local/share/libs/scripts pull > /dev/null || true

. ~/.local/share/libs/scripts/ansi.sh
. ~/.local/share/libs/scripts/args.sh
. ~/.local/share/libs/scripts/args-version.sh
. ~/.local/share/libs/scripts/args-help.sh

# echo the first argument and run
echoRun() {
  ansi::out "${FG_CYAN}$@${RESET_ALL}"
  eval "$@"
}

echoRunBold() {
  ansi::out "${BOLD}${FG_CYAN}$@${RESET_ALL}"
  eval "$@"
}

# set up doas
command -v doas &>/dev/null && [ -f /etc/doas.conf ] && alias sudo='doas' || true
