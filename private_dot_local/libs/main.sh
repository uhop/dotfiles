# include options.bash
command -v git &> /dev/null && git -C ~/.local/share/libs/scripts pull > /dev/null || true

. ~/.local/share/libs/scripts/ansi.sh
. ~/.local/share/libs/scripts/args.sh
. ~/.local/share/libs/scripts/args-version.sh
. ~/.local/share/libs/scripts/args-help.sh

# echo the first argument and run
echoRun() {
  echo -e "\033[36m$@\033[0m"
  eval "$@"
}

echoRunBold() {
  echo -e "\033[1;36m$@\033[0m"
  eval "$@"
}

# set up doas
command -v doas &>/dev/null && [ -f /etc/doas.conf ] && alias sudo='doas' || true
