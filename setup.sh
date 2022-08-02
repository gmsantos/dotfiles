#!/usr/bin/env sh

set -x

DOT_FILES_DIR=$PWD

sudo apt update
sudo apt install -y zsh

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
sudo usermod --shell /bin/zsh $USER

cd $HOME/.oh-my-zsh/custom/plugins

git submodule add -f https://github.com/djui/alias-tips
git submodule add -f https://github.com/zsh-users/zsh-autosuggestions
git submodule update --init

cd $DOT_FILES_DIR

rsync --exclude ".git/" --exclude "setup.sh" -av . $HOME
