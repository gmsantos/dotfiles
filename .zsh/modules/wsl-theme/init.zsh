#
# Matches the shell's colours to the current Windows apps theme. Exports
# ${WSL_APPS_THEME} as `light` or `dark`, restyles zsh-autosuggestions to suit,
# and runs every function named in ${wsl_theme_functions} so that prompt themes
# can repaint themselves. Only present under WSL, where reg.exe is on the path.
#
# Configure with:
#   zstyle ':zim:wsl-theme' light-style   'fg=250'
#   zstyle ':zim:wsl-theme' dark-style    'fg=8'
#   zstyle ':zim:wsl-theme' refresh-after 5      # minutes
#

typeset -g _wsl_theme_cache=${ZSH_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/zsh}/wsl-theme
typeset -gi _wsl_theme_mtime=0
typeset -gi _wsl_theme_ttl=0
typeset -gi _wsl_theme_refreshed=0
typeset -ga wsl_theme_functions

zmodload zsh/datetime 2>/dev/null

() {
  emulate -L zsh
  setopt local_options extended_glob

  local -i minutes
  zstyle -s ':zim:wsl-theme' refresh-after minutes || minutes=5
  _wsl_theme_ttl=$(( minutes * 60 ))

  if [[ -s ${_wsl_theme_cache} ]]; then
    # Refresh in the background once the cached value is stale, so that
    # querying the registry never blocks an interactive shell.
    local -a stale=(${_wsl_theme_cache}(#qNmm+${minutes}))
    if (( ${#stale} )); then
      _wsl_theme_refreshed=${EPOCHSECONDS:-0}
      wsl-theme-refresh ${_wsl_theme_cache} &!
    fi
  else
    # Nothing cached yet, so pay for the query once.
    wsl-theme-refresh ${_wsl_theme_cache}
    _wsl_theme_refreshed=${EPOCHSECONDS:-0}
  fi
}

wsl-theme-apply

# Age the cache out and repaint mid-session, so a long-lived shell tracks the
# Windows theme without being restarted.
autoload -Uz add-zsh-hook && add-zsh-hook precmd wsl-theme-precmd
