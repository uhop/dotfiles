#!/bin/bash

# Install the Ultimate VIM: https://github.com/amix/vimrc
if [ ! -d ~/.vim_runtime ]; then
  git clone --depth=1 https://github.com/amix/vimrc.git ~/.vim_runtime
  sh ~/.vim_runtime/install_awesome_vimrc.sh
fi
