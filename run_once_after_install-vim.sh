#!/usr/bin/env bash

# Install the Ultimate VIM: https://github.com/amix/vimrc
if [ ! -d ~/.vim_runtime ]; then
  CYAN=$(tput setaf 6)
  RESET=$(tput sgr0)
  echo "${CYAN}Installing the Ultimate VIM...${RESET}"
  git clone --depth=1 https://github.com/amix/vimrc.git ~/.vim_runtime
  sh ~/.vim_runtime/install_awesome_vimrc.sh
fi
