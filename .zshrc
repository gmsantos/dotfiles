# Start configuration added by Zim Framework install {{{
#
# User configuration sourced by interactive shells
#

# -----------------
# Zsh configuration
# -----------------

#
# History
#

# Remove older command from the history if a duplicate is to be added.
setopt HIST_IGNORE_ALL_DUPS

# Don't record commands that start with a space. Prefix one-off commands that
# contain secrets with a space to keep them out of ~/.zsh_history.
setopt HIST_IGNORE_SPACE

#
# Input/output
#

# Set editor default keymap to emacs (`-e`) or vi (`-v`)
bindkey -e

# Prompt for spelling correction of commands.
#setopt CORRECT

# Customize spelling correction prompt.
#SPROMPT='zsh: correct %F{red}%R%f to %F{green}%r%f [nyae]? '

# Remove path separator from WORDCHARS.
WORDCHARS=${WORDCHARS//[\/]}

# --------------------
# Module configuration
# --------------------

#
# oh-my-zsh plugin compatibility
#

# The oh-my-zsh kubectl plugin caches its generated completion here. This has to
# be on fpath before the completion module runs compinit.
export ZSH_CACHE_DIR=${XDG_CACHE_HOME:-${HOME}/.cache}/zsh
[[ -d ${ZSH_CACHE_DIR}/completions ]] || mkdir -p ${ZSH_CACHE_DIR}/completions
fpath=(${ZSH_CACHE_DIR}/completions ${fpath})

# The oh-my-zsh git plugin calls these, but they are defined in its lib/git.zsh,
# which we don't load.
function git_current_branch {
  local ref
  ref=$(git symbolic-ref --quiet HEAD 2>/dev/null) || {
    (( $? == 128 )) && return 0
    ref=$(git rev-parse --short HEAD 2>/dev/null) || return 0
  }
  print -r -- ${ref#refs/heads/}
}
function current_branch { git_current_branch }

#
# input
#

# Append `../` to your input for each `.` you type after an initial `..`
#zstyle ':zim:input' double-dot-expand yes

#
# termtitle
#

# Set a custom terminal title format using prompt expansion escape sequences.
# See http://zsh.sourceforge.net/Doc/Release/Prompt-Expansion.html#Simple-Prompt-Escapes
# If none is provided, the default '%n@%m: %~' is used.
#zstyle ':zim:termtitle' format '%1~'

#
# zsh-autosuggestions
#

# Disable automatic widget re-binding on each precmd. This can be set when
# zsh-users/zsh-autosuggestions is the last module in your ~/.zimrc.
ZSH_AUTOSUGGEST_MANUAL_REBIND=1

# Customize the style that the suggestions are shown with.
# See https://github.com/zsh-users/zsh-autosuggestions/blob/master/README.md#suggestion-highlight-style
#ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=242'

#
# zsh-syntax-highlighting
#

# Set what highlighters will be used.
# See https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/docs/highlighters.md
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)

# Customize the main highlighter styles.
# See https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/docs/highlighters/main.md#how-to-tweak-it
#typeset -A ZSH_HIGHLIGHT_STYLES
#ZSH_HIGHLIGHT_STYLES[comment]='fg=242'

# ------------------
# Initialize modules
# ------------------

ZIM_HOME=${ZDOTDIR:-${HOME}}/.zim
# Download zimfw plugin manager if missing.
if [[ ! -e ${ZIM_HOME}/zimfw.zsh ]]; then
  if (( ${+commands[curl]} )); then
    curl -fsSL --create-dirs -o ${ZIM_HOME}/zimfw.zsh \
        https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
  else
    mkdir -p ${ZIM_HOME} && wget -nv -O ${ZIM_HOME}/zimfw.zsh \
        https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
  fi
fi
# Install missing modules, and update ${ZIM_HOME}/init.zsh if missing or outdated.
if [[ ! ${ZIM_HOME}/init.zsh -nt ${ZIM_CONFIG_FILE:-${ZDOTDIR:-${HOME}}/.zimrc} ]]; then
  source ${ZIM_HOME}/zimfw.zsh init
fi
# Initialize modules.
source ${ZIM_HOME}/init.zsh
# }}} End configuration added by Zim Framework install

# Load homebrew env to shell, on the machines that have it. Its own installer
# prints this line with the prefix baked in, but the prefix differs per
# platform and a missing brew makes every shell start with a "no such file or
# directory" error, so look for it instead.
for _brew in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [[ -x ${_brew} ]]; then
    eval "$(${_brew} shellenv)"
    break
  fi
done
unset _brew

# Open URLs through xdg-open, silencing WSL interop's "tcgetpgrp failed: Not a
# tty" noise (see ~/.local/bin/xdg-browser).
export BROWSER="$HOME/.local/bin/xdg-browser"

# Add extra paths to PATH
export PATH=$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH

# Sensitive exports live in ~/.zsh_secrets (mode 600, never committed).
if [[ -f ~/.zsh_secrets ]]; then
  source ~/.zsh_secrets
fi

