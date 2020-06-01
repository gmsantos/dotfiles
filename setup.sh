#!/usr/bin/env sh

set -x

DOT_FILES_DIR=$PWD

sudo apt update
sudo apt install -y \
  zsh \
  python3 \
  python3-pip \
  php-cli

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

cd $HOME/.oh-my-zsh/custom/plugins

git submodule add https://github.com/djui/alias-tips
git submodule add https://github.com/zsh-users/zsh-autosuggestions
git submodule update --init

cd $DOT_FILES_DIR

find -type f -not -iwholename '*.git/*' -not -iname 'setup.sh' -exec cp -t $HOME '{}' ';'
