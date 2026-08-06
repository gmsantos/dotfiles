# PATH has to be complete before Zim initializes. Zim's completion module runs
# compinit, which only scans the fpath it sees at that moment, and its utility
# module probes `$+commands[...]`, which makes zsh hash every directory in PATH.
# Setting PATH afterwards meant brew's site-functions were never scanned (brew
# completions only worked by accident, via the FPATH that `brew shellenv`
# exports and child shells inherit) and forced a second hash rebuild over the
# ~5500 files the /mnt/c entries hold. Keep all of this above the Zim block.

# `path`/`fpath` are the arrays tied to PATH/FPATH; -U keeps them free of
# duplicates, so re-sourcing this file does not grow them each time. FPATH is
# included because `brew shellenv` exports it: without -U a nested shell
# inherits a full fpath and re-adds every Zim module directory on top of it.
typeset -gU path PATH fpath FPATH

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

# Add extra paths to PATH.
path=($HOME/bin $HOME/.local/bin /usr/local/bin $path)

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

# The oh-my-zsh kubectl plugin writes its generated completion here. The
# directory is deliberately NOT on fpath: the plugin rewrites _kubectl on every
# single startup, and Zim's completion module fingerprints the mtime of every
# file in fpath to decide whether ~/.zcompdump is still valid. With it on fpath
# each shell invalidated the next one's dump, so compinit rebuilt from scratch
# every time (~590ms of a ~950ms startup). kubectl completion is served from
# ${ZSH_COMPLETIONS_DIR} below instead, which only changes on kubectl upgrades.
export ZSH_CACHE_DIR=${XDG_CACHE_HOME:-${HOME}/.cache}/zsh
[[ -d ${ZSH_CACHE_DIR}/completions ]] || mkdir -p ${ZSH_CACHE_DIR}/completions

# Prune it if we inherited it. `brew shellenv` exports FPATH, so a shell started
# from one that did have this directory on fpath would otherwise keep dragging
# it along, and so would everything that shell spawns.
fpath=(${fpath:#${ZSH_CACHE_DIR}/completions})

# Hand-managed completions, stable across startups so they never invalidate the
# compinit dump. _kubectl is regenerated only when the kubectl binary it was
# built from changes, so it always matches whichever kubectl is first on PATH
# rather than whichever _kubectl happens to be shipped by a package.
typeset -g ZSH_COMPLETIONS_DIR=${ZDOTDIR:-${HOME}}/.zsh/completions
[[ -d ${ZSH_COMPLETIONS_DIR} ]] || mkdir -p ${ZSH_COMPLETIONS_DIR}
fpath=(${ZSH_COMPLETIONS_DIR} ${fpath})
# Pick the first kubectl on PATH that is actually executable. The `-*` qualifier
# resolves symlinks, which skips /usr/local/bin/kubectl -- Docker Desktop's WSL
# integration leaves that pointing into /mnt/wsl/docker-desktop, which is
# unmounted whenever Docker Desktop isn't running. $commands[kubectl] happily
# returns that dangling link, and comparing mtimes against a link that cannot be
# stat'd made the freshness test below fail on every startup.
() {
  emulate -L zsh -o EXTENDED_GLOB
  # Skip the /mnt/* entries WSL interop appends: they are DrvFs, where a stat
  # costs milliseconds rather than microseconds, and a Windows kubectl.exe is
  # not something we would want to generate zsh completion from anyway.
  local -a kubectl_bins=(${^${path:#/mnt/*}}/kubectl(N-*))
  local kubectl_bin=${kubectl_bins[1]}
  [[ -n ${kubectl_bin} ]] || return 0

  # Key the cache on which binary produced it and that binary's mtime, rather
  # than on mtime ordering. Replacing kubectl with a different install can leave
  # a newer completion file sitting next to an older binary -- swapping brew's
  # kubernetes-cli for the pkgs.k8s.io package did exactly that -- and an `-nt`
  # test accepts the stale cache. Comparing for equality catches downgrades and
  # sideways moves too. The stamp lives outside fpath so it cannot perturb the
  # compinit dump fingerprint.
  local stamp=${ZSH_CACHE_DIR}/kubectl-completion.stamp
  local -a bin_mtime
  zmodload -F zsh/stat b:zstat && zstat -A bin_mtime +mtime ${kubectl_bin:A} || return 0
  local want="${kubectl_bin:A} ${bin_mtime[1]}"
  [[ -s ${ZSH_COMPLETIONS_DIR}/_kubectl && -r ${stamp} && "$(<${stamp})" == ${want} ]] && return 0
  if ${kubectl_bin} completion zsh >| ${ZSH_COMPLETIONS_DIR}/_kubectl 2>/dev/null; then
    print -r -- ${want} >| ${stamp}
  else
    command rm -f ${ZSH_COMPLETIONS_DIR}/_kubectl ${stamp}
  fi
}

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
# completion
#

# Docker Desktop's WSL integration symlinks /usr/share/zsh/vendor-completions/_docker
# into /mnt/wsl/docker-desktop, which is unmounted whenever Docker Desktop isn't
# running. Zim's completion module zstats every file in fpath and gives up on the
# first one that's missing, so compinit never runs, compdef is never defined, and
# every plugin that calls it (oh-my-zsh git, kubectl, kubeswitch) errors out at
# startup. Replace any directory holding a dangling link -- they're root-owned, so
# the link itself can't be removed -- with a mirror of its remaining entries.
() {
  emulate -L zsh -o EXTENDED_GLOB
  local zdir zmirror
  local -a zbroken zgood zfpath
  for zdir in ${fpath}; do
    zbroken=(${zdir}/*(N-@))
    if (( ! ${#zbroken} )); then
      zfpath+=(${zdir})
      continue
    fi
    zmirror=${ZSH_CACHE_DIR}/fpath/${zdir//\//%}
    zgood=(${zdir}/*(N^-@))
    command rm -rf ${zmirror} && command mkdir -p ${zmirror} &&
        { (( ! ${#zgood} )) || command ln -s ${zgood} ${zmirror}/ } || continue
    zfpath+=(${zmirror})
  done
  fpath=(${zfpath})
}

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

# Open URLs through xdg-open, silencing WSL interop's "tcgetpgrp failed: Not a
# tty" noise (see ~/.local/bin/xdg-browser).
export BROWSER="$HOME/.local/bin/xdg-browser"

# Sensitive exports live in ~/.zsh_secrets (mode 600, never committed).
if [[ -f ~/.zsh_secrets ]]; then
  source ~/.zsh_secrets
fi

# Ubuntu 26.04 ships uutils ls 0.8.0, which drops the name sort entirely when
# given --group-directories-first (LP #2154042). Zim's utility module sets that
# flag, so override its alias with GNU ls from the gnu-coreutils package. Drop
# this once /usr/bin/ls --version reports uutils >= 0.9.0.
if (( $+commands[gnuls] )); then
  alias ls='gnuls --group-directories-first --color=auto'
fi

