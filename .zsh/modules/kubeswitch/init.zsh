# vim:et sts=2 sw=2 ft=zsh
#
# ktx / kns: switch the current Kubernetes context and namespace.
#
# kubectl burns ~1.7s here before it does any work, so everything that only
# reads the kubeconfig -- the context list, completion, the picker -- is done in
# the shell, reusing the kubecontext module's reader. The switch itself is one
# scalar in that same YAML, so it is written in the shell too, and kubectl is
# kept as the fallback for any config whose shape we do not recognize.
# Namespaces are the exception: they live in the cluster, not the kubeconfig, so
# the list is fetched once per context and cached until -r or the TTL. ktx warms
# that cache in the background for the context it switches to, which is what
# makes the next `kns` instant.
#
# Each takes a name, `-` for the previous one, or nothing for a picker:
#   ktx                    pick a context from a list
#   ktx docker-desktop     switch to it, by name or unique substring
#   ktx -                  back to the previous context
#   kns kube-system        switch namespace in the current context
#   kns -r                 refresh this context's namespace list first
#
# The picker moves with the arrow keys (or ^P/^N), filters as you type, picks
# with Enter and cancels with Esc; fzf drives it instead when installed, and a
# numbered prompt takes over when there is no terminal to drive.
#
# Both complete their argument, and the prompt follows along on its own: the
# kubecontext module notices the kubeconfig change on the next precmd.
#

zmodload -F zsh/datetime p:EPOCHSECONDS
zmodload -F zsh/stat b:zstat

# mkdir, mv and chmod as builtins: the point of the fast path is that switching
# forks nothing at all.
if ! zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm b:zf_chmod 2>/dev/null; then
  zf_mkdir() { command mkdir "${@}" }
  zf_mv()    { command mv "${@}" }
  zf_rm()    { command rm "${@}" }
  zf_chmod() { command chmod "${@}" }
fi

typeset -g _kubeswitch_state=${XDG_STATE_HOME:-${HOME}/.local/state}/kubeswitch
typeset -g _kubeswitch_cache=${XDG_CACHE_HOME:-${HOME}/.cache}/kubeswitch
# Namespaces are created and deleted far more slowly than a day, and -r is there
# for the times they are not.
typeset -gi _kubeswitch_ns_ttl=86400

# Fills the caller's `ctxs`, `ctxns`, `cur` and `curns` from the kubeconfig.
#
# kubecontext's reader already understands the shapes kubectl writes and reports
# every context it saw as a key of `_kubecontext_ns`, so this is free. The
# kubectl fallback keeps ktx working if that module is ever dropped, at the cost
# of the two invocations the module exists to avoid.
_kubeswitch_load() {
  emulate -L zsh

  ctxs=() ctxns=() cur= curns=

  if (( ${+functions[_kubecontext_read]} )); then
    local -a files=(${(s.:.)${KUBECONFIG:-${HOME}/.kube/config}})
    local file
    local _kubecontext_current=
    local -A _kubecontext_ns

    for file in ${files}; do
      [[ -r ${file} ]] && _kubecontext_read ${file}
    done

    ctxs=(${(ko)_kubecontext_ns})
    # Quoted: a context that names no namespace has an empty value, and an
    # unquoted pair list drops it, which leaves the assignment one word short.
    ctxns=("${(@kv)_kubecontext_ns}")
    cur=${_kubecontext_current}
  fi

  if (( ! ${#ctxs} )); then
    ctxs=(${(f)"$(kubectl config get-contexts -o name 2>/dev/null)"})
    cur="$(kubectl config current-context 2>/dev/null)"
  fi

  [[ -n ${cur} ]] && curns=${ctxns[${cur}]:-default}
  (( ${#ctxs} ))
}

# ---------------------------------------------------------------------------
# Namespace cache
# ---------------------------------------------------------------------------

# Cache path for context ${1}, into REPLY. Context names carry cluster paths
# and, on EKS, whole ARNs.
_kubeswitch_ns_file() {
  REPLY=${_kubeswitch_cache}/ns/${${${1//\//%2F}//:/%3A}//$'\n'/}
}

# Waits ${1} hundredths of a second without forking, where there is a builtin
# that can.
if zmodload -F zsh/zselect b:zselect 2>/dev/null; then
  _kubeswitch_nap() { zselect -t ${1} 2>/dev/null }
else
  _kubeswitch_nap() { command sleep $(( ${1} / 100.0 )) }
fi

# Asks the cluster for context ${1}'s namespaces and rewrites its cache entry.
# Sets the caller's `nss` and returns non-zero when the cluster does not answer.
#
# --context is explicit because this also runs detached, after ktx has returned
# and the user may already have switched somewhere else.
_kubeswitch_ns_fetch() {
  emulate -L zsh

  local ctx=${1} file lock tmp
  local -a fetched
  local -A st
  local -i owned=0 waited=0
  local REPLY

  _kubeswitch_ns_file ${ctx}
  file=${REPLY}
  lock=${file}.fetching
  zf_mkdir -p -- ${file:h} 2>/dev/null

  # One request per context at a time. The shell that takes the lock does the
  # asking; a shell that arrives while it is out -- typically the kns right
  # after the ktx that warmed this cache -- waits for that answer rather than
  # asking the cluster the same question a second time.
  if zf_mkdir ${lock} 2>/dev/null; then
    owned=1
  elif zstat -H st -- ${lock} 2>/dev/null &&
      (( EPOCHSECONDS - st[mtime] > 20 )); then
    # Nothing outlives the request timeout by that much except a killed shell.
    zf_rm -rf -- ${lock} 2>/dev/null
    zf_mkdir ${lock} 2>/dev/null && owned=1
  fi

  if (( ! owned )); then
    while (( waited < 1200 )) && [[ -d ${lock} ]]; do
      _kubeswitch_nap 5
      (( waited += 5 ))
    done
    if [[ -r ${file} ]]; then
      nss=(${(f)"$(<${file})"})
      (( ${#nss} )) && return 0
    fi
    # It came back empty-handed, so there is nothing to inherit; ask anyway.
  fi

  {
    fetched=(${(f)"$(kubectl get namespaces -o name --context=${ctx} \
        --request-timeout=10s 2>/dev/null)"})
    fetched=(${fetched#namespace/})
    (( ${#fetched} )) || return 1

    # Written aside and moved into place: a reader never sees half a list.
    tmp=${file}.${RANDOM}
    if print -rl -- ${fetched} >! ${tmp} 2>/dev/null; then
      zf_mv -f -- ${tmp} ${file} 2>/dev/null || zf_rm -f -- ${tmp} 2>/dev/null
    fi

    nss=(${fetched})
    return 0
  } always {
    (( owned )) && zf_rm -rf -- ${lock} 2>/dev/null
  }
}

# Namespace names for context ${1}, into the caller's `nss`. Refetches when ${2}
# is non-zero or the cache has aged out. Returns non-zero only when there is
# nothing to show at all.
_kubeswitch_ns_load() {
  emulate -L zsh

  local ctx=${1} file
  local -i refresh=${2}
  local -A st
  local REPLY

  _kubeswitch_ns_file ${ctx}
  file=${REPLY}
  nss=()

  if (( ! refresh )) && zstat -H st -- ${file} 2>/dev/null &&
      (( EPOCHSECONDS - st[mtime] < _kubeswitch_ns_ttl )); then
    nss=(${(f)"$(<${file})"})
    (( ${#nss} )) && return 0
  fi

  _kubeswitch_ns_fetch ${ctx} && return 0

  # Unreachable cluster, expired credentials, or no permission to list. A stale
  # list still beats none, and the switch itself never touches the API.
  if [[ -r ${file} ]]; then
    nss=(${(f)"$(<${file})"})
    (( ${#nss} )) && return 0
  fi
  return 1
}

# Refetches context ${1}'s namespaces detached from this shell, so the cost of
# reaching the cluster is paid while the user is still reading ktx's output
# rather than at the start of their next kns. Nothing here reports failure:
# kns falls back to a synchronous fetch, and then to the stale list.
_kubeswitch_ns_prefetch() {
  [[ -n ${1} ]] || return 0
  ( _kubeswitch_ns_fetch ${1} >/dev/null 2>&1 & ) 2>/dev/null
}

# ---------------------------------------------------------------------------
# Writing the kubeconfig
# ---------------------------------------------------------------------------

# The one kubeconfig the shell is allowed to edit, into REPLY.
#
# kubectl writes a change back to whichever of the merged files defines the
# entry, and reproducing that is not worth it: with a single file there is no
# question, and everything else -- a merged KUBECONFIG, a read-only file, CRLF
# line endings -- returns non-zero and goes back to kubectl.
_kubeswitch_config() {
  emulate -L zsh

  local -a files=(${(s.:.)${KUBECONFIG:-${HOME}/.kube/config}})
  REPLY=
  (( ${#files} == 1 )) || return 1
  # Through the symlink, so a link to a shared config keeps pointing at it.
  local file=${files[1]:A}
  [[ -f ${file} && -w ${file} ]] || return 1
  REPLY=${file}
}

# Replaces the caller's `lines` array in ${1}, atomically and with the mode the
# file already had.
_kubeswitch_config_write() {
  emulate -L zsh

  local file=${1} tmp=${1}.kubeswitch.${RANDOM}
  local -A st

  # Quoted, or the blank lines someone left in their config disappear.
  print -rl -- "${(@)lines}" >! ${tmp} 2>/dev/null ||
      { zf_rm -f -- ${tmp} 2>/dev/null; return 1 }
  zstat -H st -- ${file} 2>/dev/null && zf_chmod $(( [##8] st[mode] & 4095 )) ${tmp} 2>/dev/null
  zf_mv -f -- ${tmp} ${file} 2>/dev/null || { zf_rm -f -- ${tmp} 2>/dev/null; return 1 }
}

# Records where the context entry that just ended keeps the values ktx and kns
# rewrite. Reads and clears the `p_*` scan state from the caller's scope, and
# keeps the first entry of a name, which is the one kubeconfig merge rules use.
_kubeswitch_edit_commit() {
  if (( ! found )) && [[ -n ${p_name} && ${p_name} == ${ctx} ]]; then
    found=1
    found_ctx_line=${p_ctx_line}
    found_ns_line=${p_ns_line}
    found_indent=${p_indent}
  fi
  p_name= p_ctx_line=0 p_ns_line=0 p_indent=0
}

# Points context ${1}'s `namespace:` at ${2}, in the shell.
#
# kubectl spends its whole startup deserializing the config to change this one
# scalar, and once the namespace list is cached that startup *is* what `kns`
# costs. So walk the shapes _kubecontext_read accepts, edit the single line,
# and hand anything less ordinary back to kubectl by returning non-zero.
_kubeswitch_set_namespace() {
  emulate -L zsh
  setopt extended_glob

  local ctx=${1} ns=${2} file
  local REPLY

  # Namespaces are DNS labels, so the value never needs YAML quoting.
  [[ ${ns} == [a-z0-9]([-a-z0-9]#[a-z0-9]|) ]] && (( ${#ns} <= 63 )) || return 1
  _kubeswitch_config || return 1
  file=${REPLY}

  local -a lines
  lines=("${(@f)"$(<${file})"}") 2>/dev/null || return 1

  local line bare trimmed value section= p_name=
  local -i i n=${#lines} indent item_indent=-1 in_context=0
  local -i p_ctx_line=0 p_ns_line=0 p_indent=0
  local -i found=0 found_ctx_line=0 found_ns_line=0 found_indent=0

  for (( i = 1; i <= n; i++ )); do
    line=${lines[i]}
    # A rewrite would have to reproduce the line endings, and this one will not.
    [[ ${line} == *$'\r' ]] && return 1
    bare=${line##[[:space:]]#}
    [[ -z ${bare} || ${bare} == \#* ]] && continue

    if [[ ${line} == [^[:space:]-]* ]]; then
      _kubeswitch_edit_commit
      (( found )) && break
      section=${${bare%%[[:space:]]#}%%:*}
      item_indent=-1 in_context=0
      continue
    fi

    [[ ${section} == contexts ]] || continue

    if [[ ${bare} == -([[:space:]]*|) ]]; then
      _kubeswitch_edit_commit
      # The entry we came for has just ended; the rest of the file is no
      # business of ours.
      (( found )) && break
      # The dash sits where the entry's keys sit; blanking it lines them up.
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
          p_name=${(Q)value}
          in_context=0
          ;;
        context:*)
          in_context=1
          p_ctx_line=i
          ;;
        *) in_context=0 ;;
      esac
    elif (( in_context )); then
      (( p_indent )) || p_indent=indent
      [[ ${trimmed} == namespace:* ]] && p_ns_line=i
    fi
  done
  _kubeswitch_edit_commit

  (( found && found_ctx_line )) || return 1

  if (( found_ns_line )); then
    line=${lines[found_ns_line]}
    # A trailing comment on the line is someone's note; do not eat it.
    [[ ${line} == *\#* ]] && return 1
    lines[found_ns_line]="${line%%[^[:space:]]*}namespace: ${ns}"
  else
    line=${lines[found_ctx_line]}
    # `context: {...}` is flow style, which this does not know how to extend.
    [[ ${${line#*context:}##[[:space:]]#} == '' ]] || return 1
    local -i pad=${found_indent}
    (( pad )) || pad=$(( ${#${line%%[^[:space:]]*}} + 2 ))
    lines[found_ctx_line,found_ctx_line]=("${line}" "${(l:pad:)}namespace: ${ns}")
  fi

  _kubeswitch_config_write ${file}
}

# Points `current-context:` at ${1}, in the shell, under the same terms as
# _kubeswitch_set_namespace.
_kubeswitch_set_current() {
  emulate -L zsh
  setopt extended_glob

  local ctx=${1} file
  local REPLY

  # Plain YAML scalars: no comment marker, no `: ` pair separator, and nothing
  # that would make the first character an indicator. An EKS ARN passes; a name
  # that does not goes to kubectl.
  [[ ${ctx} == [[:alnum:]/]* && ${ctx} != *([[:space:]]\#|:[[:space:]]|$'\n')* ]] || return 1
  _kubeswitch_config || return 1
  file=${REPLY}

  local -a lines
  lines=("${(@f)"$(<${file})"}") 2>/dev/null || return 1

  local line
  local -i i n=${#lines} at=0
  for (( i = 1; i <= n; i++ )); do
    line=${lines[i]}
    [[ ${line} == *$'\r' ]] && return 1
    [[ ${line} == current-context:* ]] || continue
    [[ ${line} == *\#* ]] && return 1
    at=i
    break
  done
  # No key to replace: kubectl decides where a new one belongs.
  (( at )) || return 1

  lines[at]="current-context: ${ctx}"
  _kubeswitch_config_write ${file}
}

_kubeswitch_remember() {
  zf_mkdir -p -- ${_kubeswitch_state} && print -rl -- ${@[2,-1]} >! ${_kubeswitch_state}/${1}
}

# ---------------------------------------------------------------------------
# Picker
# ---------------------------------------------------------------------------

# Redraws the menu from the caller's state and leaves the cursor back at the
# top of the block, ready for the next draw.
_kubeswitch_menu_draw() {
  local out= item
  local -i i last width=$(( ${COLUMNS:-80} - 4 ))
  (( width < 8 )) && width=8

  rows=$(( height - 3 ))
  (( rows > ${#matches} )) && rows=${#matches}
  (( rows < 0 )) && rows=0

  # Scroll only as far as it takes to keep the selection on screen.
  (( sel < top )) && top=sel
  (( sel > top + rows - 1 )) && top=$(( sel - rows + 1 ))
  (( top < 1 )) && top=1

  out=$'\e[2K'"${label}> ${filter}"
  (( ${#matches} != ${#all} )) && out+=" (${#matches}/${#all})"
  out+=$'\n'

  last=$(( top + rows - 1 ))
  for (( i = top; i <= last; i++ )); do
    item=${matches[i]}
    (( ${#item} > width )) && item="${item[1,width-1]}…"
    [[ ${matches[i]} == "${current}" ]] && item="* ${item}" || item="  ${item}"
    if (( i == sel )); then
      out+=$'\e[2K\e[7m'"> ${item}"$'\e[0m'$'\n'
    else
      out+=$'\e[2K'"  ${item}"$'\n'
    fi
  done

  # Erase whatever a longer list left below, then rewind.
  drawn=$(( rows + 1 ))
  print -nu2 -- "${out}"$'\e[J'$'\e['${drawn}'A'
}

# Reapplies the filter, keeping the highlight on the same entry when it is still
# in the list.
_kubeswitch_menu_filter() {
  # `(#i)` needs extended_glob, and `(b)` keeps a typed `*` or `[` literal.
  setopt localoptions extended_glob

  local keep=${matches[sel]}

  if [[ -n ${filter} ]]; then
    matches=("${(@M)all:#*(#i)${(b)filter}*}")
  else
    matches=("${all[@]}")
  fi

  sel=${matches[(Ie)${keep}]}
  (( sel )) || sel=1
  top=1
}

# Takes the menu back off the screen. A draw always leaves the cursor at the top
# of its block, so erasing forward from where it stands is enough -- rewinding
# again here would eat the lines above the menu.
_kubeswitch_menu_restore() {
  (( drawn )) && print -nu2 $'\e[J'
  drawn=0
  print -nu2 $'\e[?25h'
}

# Menu of ${3..} on the terminal, choice into REPLY, marking ${2} as current.
# Arrows or ^P/^N move, printable keys filter, Enter picks, Esc cancels.
# Returns 2 when there is no terminal to drive, so the caller can fall back.
_kubeswitch_menu() {
  emulate -L zsh
  setopt extended_glob

  local label=${1} current=${2}
  shift 2
  local -a all=("${@}") matches=("${@}")
  local filter= key seq rest
  local -i sel=1 top=1 rows=0 drawn=0 height=${LINES:-0} ret=1
  # How long the rest of a cursor key has to arrive before Esc counts as Esc.
  # ZLE's own answer, in hundredths of a second, with a floor for the terminals
  # that split the sequence across a slow link.
  local -F wait=$(( ${KEYTIMEOUT:-40} / 100.0 ))
  (( wait < 0.1 )) && wait=0.1

  [[ -t 0 && -t 2 ]] || return 2
  (( height >= 6 )) || return 2

  sel=${all[(Ie)${current}]}
  (( sel )) || sel=1

  # ^C arrives as a signal, not a key, and it must not leave the terminal
  # without a cursor.
  trap '_kubeswitch_menu_restore; return 1' INT
  print -nu2 $'\e[?25l'

  {
    while true; do
      _kubeswitch_menu_draw
      read -sk 1 key || break

      case ${key} in
        $'\n'|$'\r')
          (( ${#matches} )) || continue
          REPLY=${matches[sel]}
          ret=0
          break
          ;;
        $'\e')
          # A lone Esc cancels; anything else is a cursor key.
          read -sk 1 -t ${wait} seq || break
          [[ ${seq} == (\[|O) ]] || break
          read -sk 1 -t ${wait} seq || break
          if [[ ${seq} == <-> ]]; then
            # CSI with parameters: keep the first, drop the rest.
            while read -sk 1 -t ${wait} rest; do
              [[ ${rest} == [~[:alpha:]] ]] && break
            done
            case ${seq} in
              5) sel=$(( sel - rows )) ;;
              6) sel=$(( sel + rows )) ;;
            esac
          else
            case ${seq} in
              A) (( sel-- )) ;;
              B) (( sel++ )) ;;
              H) sel=1 ;;
              F) sel=${#matches} ;;
            esac
          fi
          ;;
        $'\C-p') (( sel-- )) ;;
        $'\C-n') (( sel++ )) ;;
        $'\C-a') sel=1 ;;
        $'\C-e') sel=${#matches} ;;
        $'\C-u')
          filter=
          _kubeswitch_menu_filter
          ;;
        $'\C-w')
          filter=${${filter%%[^[:space:]]#}%%[[:space:]]#}
          _kubeswitch_menu_filter
          ;;
        $'\C-?'|$'\C-h')
          [[ -n ${filter} ]] || continue
          filter=${filter[1,-2]}
          _kubeswitch_menu_filter
          ;;
        $'\C-g'|$'\C-c'|$'\C-d') break ;;
        [[:print:]])
          filter+=${key}
          _kubeswitch_menu_filter
          ;;
      esac

      (( sel < 1 )) && sel=1
      (( sel > ${#matches} )) && sel=${#matches}
    done
  } always {
    _kubeswitch_menu_restore
  }

  return ret
}

# The menu without a terminal: the list, then one line of input. Takes an index,
# a name, or any substring matching exactly one entry; empty input cancels.
_kubeswitch_prompt() {
  emulate -L zsh
  setopt extended_glob

  local label=${1} current=${2}
  shift 2
  local -a items=(${@})

  local -i i width=${#${#items}}
  for (( i = 1; i <= ${#items}; i++ )); do
    if [[ ${items[i]} == ${current} ]]; then
      print -ru2 -- "${(l:width:)i}) * ${items[i]}"
    else
      print -ru2 -- "${(l:width:)i})   ${items[i]}"
    fi
  done

  local answer
  read -r "answer?${label}> " || { print -ru2; return 1 }
  answer=${${answer##[[:space:]]#}%%[[:space:]]#}
  [[ -n ${answer} ]] || return 1

  if [[ ${answer} == <-> ]]; then
    if (( answer < 1 || answer > ${#items} )); then
      print -ru2 -- "${label}: no entry ${answer}"
      return 1
    fi
    REPLY=${items[answer]}
    return 0
  fi

  if (( ${items[(Ie)${answer}]} )); then
    REPLY=${answer}
    return 0
  fi

  local -a hits=(${(M)items:#*${answer}*})
  if (( ${#hits} == 1 )); then
    REPLY=${hits[1]}
    return 0
  elif (( ${#hits} )); then
    print -ru2 -- "${label}: ${answer} matches ${#hits}:"
    print -rlu2 -- ${hits/#/  }
  else
    print -ru2 -- "${label}: nothing matches ${answer}"
  fi
  return 1
}

# Picks one of ${3..}, into REPLY, marking ${2} as current.
_kubeswitch_pick() {
  emulate -L zsh

  local label=${1} current=${2}
  shift 2
  local -a items=(${@})
  (( ${#items} )) || return 1
  REPLY=

  if (( ${+commands[fzf]} )); then
    # One option per word: fzf reads `--header` and its value as two arguments,
    # and `${current:+--header "current: ..."}` is a single one.
    local -a opts=(--reverse --height 40% --select-1 --prompt "${label}> ")
    [[ -n ${current} ]] && opts+=(--header "current: ${current}")

    REPLY=$(print -rl -- "${items[@]}" | fzf "${opts[@]}" 2>/dev/null)
    local -i ret=$?
    # 2 is fzf declining to run -- no terminal, an option it does not have --
    # and only then is there anything left to try. 1 and 130 are its answer.
    if (( ret != 2 )); then
      [[ -n ${REPLY} ]] || return 1
      return ret
    fi
    REPLY=
  fi

  _kubeswitch_menu ${label} "${current}" ${items}
  local -i ret=$?
  # 2 alone means there was no terminal to draw on; a cancel is the caller's
  # answer and must not be retried as a prompt.
  (( ret != 2 )) && return ret
  _kubeswitch_prompt ${label} "${current}" ${items}
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

ktx() {
  emulate -L zsh
  setopt extended_glob

  if [[ ${1} == (-h|--help) ]]; then
    print -r -- 'Usage: ktx [context|-]

Switch the current kubectl context. With no argument, pick one from a list;
with `-`, go back to the previous one. Either way the new context'\''s namespace
list is refreshed in the background, so the next kns needs no API call.'
    return 0
  elif (( $# > 1 )); then
    print -ru2 -- 'ktx: too many arguments'
    return 1
  fi

  local -a ctxs
  local -A ctxns
  local cur= curns= target=${1} REPLY=

  if ! _kubeswitch_load; then
    print -ru2 -- 'ktx: no contexts in the kubeconfig'
    return 1
  fi

  if [[ -z ${target} ]]; then
    _kubeswitch_pick context "${cur}" ${ctxs} || return 1
    target=${REPLY}
  elif [[ ${target} == - ]]; then
    target="$(<${_kubeswitch_state}/prev-context)" 2>/dev/null
    if [[ -z ${target} ]]; then
      print -ru2 -- 'ktx: no previous context'
      return 1
    fi
  elif (( ! ${ctxs[(Ie)${target}]} )); then
    # A name given on the command line gets the same substring match the picker
    # allows, so tab completion and typing three characters agree.
    local -a hits=(${(M)ctxs:#*${target}*})
    if (( ${#hits} == 1 )); then
      target=${hits[1]}
    elif (( ${#hits} )); then
      print -ru2 -- "ktx: ${target} matches ${#hits}:"
      print -rlu2 -- ${hits/#/  }
      return 1
    else
      print -ru2 -- "ktx: no such context: ${target}"
      return 1
    fi
  fi

  if (( ! ${ctxs[(Ie)${target}]} )); then
    print -ru2 -- "ktx: no such context: ${target}"
    return 1
  fi
  if [[ ${target} == ${cur} ]]; then
    print -r -- "ktx: already on ${target} (${curns})"
    return 0
  fi

  _kubeswitch_set_current ${target} ||
      kubectl config use-context -- ${target} >/dev/null || return
  [[ -n ${cur} ]] && _kubeswitch_remember prev-context ${cur}
  print -r -- "ktx: ${target} (${ctxns[${target}]:-default})"
  _kubeswitch_ns_prefetch ${target}
}

kns() {
  emulate -L zsh
  setopt extended_glob

  local -i refresh=0
  local target=

  while (( $# )); do
    case ${1} in
      -h|--help)
        print -r -- 'Usage: kns [-r] [namespace|-]

Switch the namespace of the current kubectl context. With no argument, pick one
from a list; with `-`, go back to the previous one. -r refetches the namespace
list, which is otherwise cached per context for a day and refreshed by ktx.'
        return 0
        ;;
      -r|--refresh) refresh=1 ;;
      -) target=- ;;
      -*)
        print -ru2 -- "kns: unrecognized option ${1}"
        return 1
        ;;
      *)
        if [[ -n ${target} ]]; then
          print -ru2 -- 'kns: too many arguments'
          return 1
        fi
        target=${1}
        ;;
    esac
    shift
  done

  local -a ctxs nss
  local -A ctxns
  local cur= curns= REPLY=

  _kubeswitch_load
  if [[ -z ${cur} ]]; then
    print -ru2 -- 'kns: no current context'
    return 1
  fi

  if [[ ${target} == - ]]; then
    local -a saved
    saved=(${(f)"$(<${_kubeswitch_state}/prev-namespace)"}) 2>/dev/null
    # The pair is only meaningful inside the context it was recorded in.
    if (( ${#saved} < 2 )) || [[ ${saved[1]} != ${cur} ]]; then
      print -ru2 -- 'kns: no previous namespace in this context'
      return 1
    fi
    target=${saved[2]}
  elif [[ -z ${target} ]]; then
    if ! _kubeswitch_ns_load ${cur} ${refresh}; then
      print -ru2 -- "kns: cannot list namespaces in ${cur}; pass one by name"
      return 1
    fi
    _kubeswitch_pick namespace "${curns}" ${nss} || return 1
    target=${REPLY}
  else
    # A name that is already known needs no API call; an unknown one is worth
    # one lookup, in case the list is simply stale.
    _kubeswitch_ns_load ${cur} ${refresh}
    if (( ${#nss} && ! ${nss[(Ie)${target}]} )); then
      local -a hits=(${(M)nss:#*${target}*})
      if (( ${#hits} == 1 )); then
        target=${hits[1]}
      elif (( ${#hits} )); then
        print -ru2 -- "kns: ${target} matches ${#hits}:"
        print -rlu2 -- ${hits/#/  }
        return 1
      else
        # Not fatal: the namespace may have just been created, and a context can
        # point at one that does not exist yet.
        print -ru2 -- "kns: ${target} is not in ${cur}'s namespace list"
      fi
    fi
  fi

  if [[ ${target} == ${curns} ]]; then
    print -r -- "kns: already on ${target}"
    return 0
  fi

  _kubeswitch_set_namespace ${cur} ${target} ||
      kubectl config set-context --current --namespace=${target} >/dev/null || return
  _kubeswitch_remember prev-namespace ${cur} ${curns}
  print -r -- "kns: ${target}"
}

_ktx() {
  # `(#m)` below is inert without extended_glob, and the completion system does
  # not guarantee it.
  setopt localoptions extended_glob

  local -a ctxs
  local -A ctxns
  local cur= curns=
  local -a display

  _kubeswitch_load || return 1
  # _describe splits its pairs on the first colon, and EKS context names are
  # ARNs, so the name half has to be escaped.
  display=("${(@)ctxs/(#m)*/${MATCH//:/\\:}:${ctxns[${MATCH}]:-default}}")

  _describe -t contexts context display
}

_kns() {
  local -a ctxs nss
  local -A ctxns
  local cur= curns=

  _kubeswitch_load || return 1
  [[ -n ${cur} ]] || return 1
  _kubeswitch_ns_load ${cur} 0 || return 1

  _describe -t namespaces namespace nss
}

if (( ${+functions[compdef]} )); then
  compdef _ktx ktx
  compdef _kns kns
fi
