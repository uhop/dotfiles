# echo the first argument and run
echoRun() {
  echo -e "\033[36m$@\033[0m"
  eval "$@"
}

echoRunBold() {
  echo -e "\033[1;36m$@\033[0m"
  eval "$@"
}
