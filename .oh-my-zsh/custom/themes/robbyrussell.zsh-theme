local ret_status="%(?:%{$fg_bold[green]%}>:%{$fg_bold[red]%}>) %{$reset_color%}"
PROMPT=$'\n%{$fg_bold[cyan]%}%~%{$reset_color%}$(git_prompt_info)\n${ret_status}'

ZSH_THEME_GIT_PROMPT_PREFIX=" %{$reset_color%}("
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%}"
ZSH_THEME_GIT_PROMPT_DIRTY=") %{$fg[red]%}✗"
ZSH_THEME_GIT_PROMPT_CLEAN=") %{$fg[green]%}✓"

