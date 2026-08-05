# vim:et sts=2 sw=2 ft=zsh
#
# A three-line prompt that stays legible on both light and dark backgrounds.
#
#   <blank line>
#   ~/full/path  branch ✓  (context:namespace)
#   >
#
# Requires the `git-info` and `prompt-pwd` zmodules. Shows the Kubernetes
# context when the `kubecontext` module is loaded, and follows the Windows apps
# theme when the `wsl-theme` module is loaded. Without wsl-theme it just uses
# the dark palette.
#
# Override any colour by setting the entry before this is sourced, e.g. in the
# module configuration section of ~/.zshrc:
#   typeset -gA prompt_adaptive_light
#   prompt_adaptive_light[pwd]=24
#

setopt nopromptbang prompt{cr,percent,sp,subst}

# The full path from ~, with no git-root or fish-style truncation.
zstyle ':zim:prompt-pwd' git-root no
zstyle ':zim:prompt-pwd:tail' length 0
zstyle ':zim:prompt-pwd:fish-style' dir-length 0

# 256-colour palettes. Every light value clears 4.5:1 against white and every
# dark value clears 4.5:1 against black, which is what stock themes get wrong:
# they reach for white, plain yellow, and colour 8, none of which survive both.
typeset -gA prompt_adaptive_dark prompt_adaptive_light
: ${prompt_adaptive_dark[pwd]:=39}     ${prompt_adaptive_light[pwd]:=25}
: ${prompt_adaptive_dark[branch]:=176} ${prompt_adaptive_light[branch]:=90}
: ${prompt_adaptive_dark[clean]:=78}   ${prompt_adaptive_light[clean]:=22}
: ${prompt_adaptive_dark[dirty]:=215}  ${prompt_adaptive_light[dirty]:=130}
: ${prompt_adaptive_dark[kube]:=75}    ${prompt_adaptive_light[kube]:=24}
: ${prompt_adaptive_dark[ns]:=80}      ${prompt_adaptive_light[ns]:=23}
: ${prompt_adaptive_dark[ok]:=78}      ${prompt_adaptive_light[ok]:=22}
: ${prompt_adaptive_dark[err]:=210}    ${prompt_adaptive_light[err]:=124}
: ${prompt_adaptive_dark[punct]:=244}  ${prompt_adaptive_light[punct]:=240}

typeset -g _prompt_adaptive_pwd=
typeset -g _prompt_adaptive_kube=
typeset -gA _prompt_adaptive_colors

# Composes the Kubernetes segment, or empties it when the `kubecontext` module
# is absent or there is no current context. PS1 holds a reference to the result
# rather than a `$(...)` call, so drawing a prompt costs no forks. Rebuilt only
# when the context changes or the palette flips, via the two hooks below.
#
# `%` is doubled because prompt escapes *are* interpreted in a substituted
# value -- that is what makes the %F colours here work -- so an unescaped one
# in a context name would corrupt the line. Command substitution is not
# re-run on the result, so a name is otherwise safe to interpolate.
_prompt_adaptive_kube_build() {
  _prompt_adaptive_kube=
  [[ -n ${kubecontext_name} ]] || return 0

  local -A c=(${(kv)_prompt_adaptive_colors})
  local ctx=${kubecontext_name//\%/%%} ns=${kubecontext_namespace//\%/%%}
  _prompt_adaptive_kube="  %F{${c[punct]}}(%f%F{${c[kube]}}${ctx}%f"
  [[ -n ${ns} ]] && _prompt_adaptive_kube+="%F{${c[punct]}}:%f%F{${c[ns]}}${ns}%f"
  _prompt_adaptive_kube+="%F{${c[punct]}})%f"
  return 0
}

_prompt_adaptive_precmd() {
  prompt-pwd _prompt_adaptive_pwd
}

# Repaints PS1 for ${1}, which is `light` or `dark`.
_prompt_adaptive_palette() {
  emulate -L zsh

  local -A c
  if [[ ${1:-${WSL_APPS_THEME}} == light ]]; then
    c=(${(kv)prompt_adaptive_light})
  else
    c=(${(kv)prompt_adaptive_dark})
  fi
  _prompt_adaptive_colors=(${(kv)c})

  if (( ${+functions[git-info]} )); then
    zstyle ':zim:git-info:branch' format "%F{${c[branch]}}%b%f"
    zstyle ':zim:git-info:commit' format "%F{${c[branch]}}%c%f"
    zstyle ':zim:git-info:clean'  format "%F{${c[clean]}}%{%G✓%}%f"
    zstyle ':zim:git-info:dirty'  format "%F{${c[dirty]}}%{%G✗%}%f"
    zstyle ':zim:git-info:action' format " %F{${c[dirty]}}%s%f"
    zstyle ':zim:git-info:ahead'  format " %F{${c[punct]}}%{%G↑%}%A%f"
    zstyle ':zim:git-info:behind' format " %F{${c[punct]}}%{%G↓%}%B%f"
    zstyle ':zim:git-info:stashed' format " %F{${c[punct]}}%{%G*%}%S%f"
    zstyle ':zim:git-info:keys' format 'prompt' '  %b%c %C%D%s%A%B%S'
  fi

  _prompt_adaptive_kube_build

  typeset -g PS1=$'\n'"%B%F{${c[pwd]}}"'${_prompt_adaptive_pwd}'"%f%b"'${(e)git_info[prompt]}${_prompt_adaptive_kube}'$'\n'"%B%(?:%F{${c[ok]}}:%F{${c[err]}})>%f%b "
}

typeset -gA git_info
if (( ${+functions[git-info]} )); then
  autoload -Uz add-zsh-hook && add-zsh-hook precmd git-info
fi
autoload -Uz add-zsh-hook && add-zsh-hook precmd _prompt_adaptive_precmd

# Recompose the segment whenever the kubecontext module reports a change.
kubecontext_functions+=(_prompt_adaptive_kube_build)

# Repaint whenever the wsl-theme module detects a change.
wsl_theme_functions+=(_prompt_adaptive_palette)
_prompt_adaptive_palette

unset RPS1
