# vim:et sts=2 sw=2 ft=zsh
#
# The current Kubernetes context and namespace, for prompts, without kubectl.
#
# `kubectl config current-context` and `kubectl config view --minify` cost
# ~300ms each here, and the oh-my-zsh kube-ps1 plugin runs both whenever the
# kubeconfig mtime moves, then rebuilds its coloured string in half a dozen
# subshells on *every* prompt. Both values are plain text in the YAML, so the
# shell can read them itself: no forks, and the result is cached until an mtime
# actually changes, leaving a couple of zstat builtin calls per prompt.
#
# Exposes:
#   $kubecontext_name       current context, empty when there is none
#   $kubecontext_namespace  its namespace, `default` when the context omits one
#   $kubecontext_functions  names of functions to call when either changes
#   kubeon / kubeoff        toggle for this shell, `-g` for every shell
#

zmodload -F zsh/stat b:zstat

typeset -g kubecontext_name= kubecontext_namespace=
typeset -ga kubecontext_functions
typeset -g _kubecontext_disable_path=${HOME}/.kube/prompt-disabled
typeset -g _kubecontext_stamp=INIT

[[ -f ${_kubecontext_disable_path} ]] && typeset -g KUBECONTEXT_ENABLED=off

# Records the list entry that just ended. kubeconfig merge rules give the first
# definition of a name priority, so an existing key is never overwritten. Reads
# and clears `entry`/`entry_ns` from the caller's scope.
_kubecontext_commit() {
  if [[ -n ${entry} ]] && (( ! ${+_kubecontext_ns[${entry}]} )); then
    _kubecontext_ns[${entry}]=${entry_ns}
  fi
  entry= entry_ns=
}

# Merges the contexts and, if it is the first to carry one, the current-context
# of ${1} into the caller's `_kubecontext_current` and `_kubecontext_ns`.
#
# This is not a YAML parser. It reads the shape kubectl writes and the shapes
# people hand-write around it: top-level keys at column 0, a `contexts:` list
# whose entries are `name` and a `context` mapping holding `namespace`, at any
# consistent indentation. Anything more exotic falls back to no namespace,
# which is what a context without one means anyway.
_kubecontext_read() {
  emulate -L zsh
  setopt extended_glob

  local -a lines
  lines=(${(f)"$(<${1})"}) 2>/dev/null || return 0

  local line bare trimmed value section= entry= entry_ns=
  local -i indent item_indent=-1 in_context=0

  for line in ${lines}; do
    line=${line%$'\r'}
    bare=${line##[[:space:]]#}
    [[ -z ${bare} || ${bare} == \#* ]] && continue

    # A column-0 key closes the previous list entry and starts a new section.
    if [[ ${line} == [^[:space:]-]* ]]; then
      _kubecontext_commit
      trimmed=${bare%%[[:space:]]#}
      section=${trimmed%%:*}
      item_indent=-1 in_context=0
      if [[ ${section} == current-context && -z ${_kubecontext_current} ]]; then
        value=${${trimmed#*:}##[[:space:]]#}
        _kubecontext_current=${(Q)value}
      fi
      continue
    fi

    [[ ${section} == contexts ]] || continue

    # `- context:` opens an entry; rewrite the dash to a space so the key it
    # sits on lines up with the entry's other keys, and take that column as the
    # entry indent. Everything deeper belongs to a nested mapping. The dash is
    # matched on the stripped line because the list itself may be indented.
    if [[ ${bare} == -([[:space:]]*|) ]]; then
      _kubecontext_commit
      line=${line/-/ }
      bare=${line##[[:space:]]#}
      item_indent=$(( ${#line} - ${#bare} ))
      in_context=0
      [[ -z ${bare} ]] && continue
    fi

    (( item_indent < 0 )) && continue
    indent=$(( ${#line} - ${#bare} ))
    (( indent < item_indent )) && continue
    trimmed=${bare%%[[:space:]]#}

    if (( indent == item_indent )); then
      case ${trimmed} in
        name:*)
          value=${${trimmed#name:}##[[:space:]]#}
          entry=${(Q)value}
          in_context=0
          ;;
        context:*) in_context=1 ;;
        *) in_context=0 ;;
      esac
    elif (( in_context )) && [[ ${trimmed} == namespace:* ]]; then
      value=${${trimmed#namespace:}##[[:space:]]#}
      entry_ns=${(Q)value}
    fi
  done

  _kubecontext_commit
}

# Notifies the registered callbacks that the pair changed.
_kubecontext_publish() {
  local fn
  for fn in ${kubecontext_functions}; do
    (( ${+functions[${fn}]} )) && ${fn}
  done
}

_kubecontext_refresh() {
  emulate -L zsh
  setopt extended_glob

  [[ ${KUBECONTEXT_ENABLED} == off ]] && return 0

  local -a files
  files=(${(s.:.)${KUBECONFIG:-${HOME}/.kube/config}})

  # Change detector: every readable config's identity, keyed by path, so
  # editing a file, adding one to KUBECONFIG, or dropping one all invalidate
  # the cache. A symlinked config contributes its own identity as well as its
  # target's. mtime alone is only second-granular, and the common ways a
  # kubeconfig changes -- `kubectl config use-context`, `sed -i`, an editor --
  # all rewrite it in well under a second, so inode and size come along to
  # catch a same-second edit. That is a race kube-ps1 loses.
  local stamp= file
  local -A st
  for file in ${files}; do
    [[ -r ${file} ]] || continue
    zstat -H st ${file} 2>/dev/null && stamp+=":${file}=${st[mtime]},${st[inode]},${st[size]}"
    [[ -L ${file} ]] && zstat -H st -L ${file} 2>/dev/null &&
        stamp+="@${st[mtime]},${st[inode]},${st[size]}"
  done
  [[ ${stamp} == "${_kubecontext_stamp}" ]] && return 0
  _kubecontext_stamp=${stamp}

  local _kubecontext_current=
  local -A _kubecontext_ns
  for file in ${files}; do
    [[ -r ${file} ]] && _kubecontext_read ${file}
  done

  local name=${_kubecontext_current} namespace=
  [[ -n ${name} ]] && namespace=${_kubecontext_ns[${name}]:-default}

  [[ ${name} == "${kubecontext_name}" && ${namespace} == "${kubecontext_namespace}" ]] && return 0
  kubecontext_name=${name}
  kubecontext_namespace=${namespace}
  _kubecontext_publish
}

kubeon() {
  emulate -L zsh
  if [[ ${1} == (-h|--help) ]]; then
    print -r -- 'Usage: kubeon [-g|--global]

Show the Kubernetes context in the prompt for this shell, or with -g for
every shell.'
    return 0
  elif [[ ${1} == (-g|--global) ]]; then
    rm -f -- ${_kubecontext_disable_path}
  elif (( $# )); then
    print -ru2 -- "kubeon: unrecognized argument ${1}"
    return 1
  fi

  KUBECONTEXT_ENABLED=on
  _kubecontext_stamp=INIT
  _kubecontext_refresh
}

kubeoff() {
  emulate -L zsh
  if [[ ${1} == (-h|--help) ]]; then
    print -r -- 'Usage: kubeoff [-g|--global]

Hide the Kubernetes context in the prompt for this shell, or with -g for
every shell.'
    return 0
  elif [[ ${1} == (-g|--global) ]]; then
    mkdir -p -- ${_kubecontext_disable_path:h} && touch -- ${_kubecontext_disable_path}
  elif (( $# )); then
    print -ru2 -- "kubeoff: unrecognized argument ${1}"
    return 1
  fi

  KUBECONTEXT_ENABLED=off
  _kubecontext_stamp=INIT
  if [[ -n ${kubecontext_name} ]]; then
    kubecontext_name= kubecontext_namespace=
    _kubecontext_publish
  fi
}

autoload -Uz add-zsh-hook && add-zsh-hook precmd _kubecontext_refresh
