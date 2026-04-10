# playbash bash completion — sourced from ~/.bashrc
_playbash() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="run push debug exec list hosts log"

  # Find the first subcommand-shaped token. Anything before it is options.
  local subcommand=""
  local i
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      run|push|debug|exec|list|hosts|log)
        subcommand="${COMP_WORDS[i]}"
        break
        ;;
    esac
  done

  # No subcommand yet → complete on the subcommand list (or top-level options).
  if [[ -z "$subcommand" ]]; then
    if [[ "$cur" == -* ]]; then
      COMPREPLY=( $(compgen -W "--bash-completion -h --help" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
    fi
    return
  fi

  case "$subcommand" in
    list|hosts)
      return
      ;;
    log)
      COMPREPLY=( $(compgen -f -- "$cur") )
      return
      ;;
    exec)
      # exec <targets> <command...> — complete targets at pos 0, then stop.
      case "$prev" in
        -n|--lines|-p|--parallel) return ;;
      esac
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-n --lines -p --parallel --self -h --help" -- "$cur") )
        return
      fi
      # Count positional args (same logic as run/debug below).
      local pos=0 skip_next=0
      for ((i = 1; i < COMP_CWORD; i++)); do
        local w="${COMP_WORDS[i]}"
        if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
        case "$w" in
          exec) ;;
          -n|--lines|-p|--parallel) skip_next=1 ;;
          -*) ;;
          *) ((pos++)) ;;
        esac
      done
      if [[ $pos -eq 0 ]]; then
        # Targets — same comma-separated completion as run/debug.
        local prefix last
        if [[ "$cur" == *,* ]]; then
          prefix="${cur%,*},"
          last="${cur##*,}"
        else
          prefix=""
          last="$cur"
        fi
        local targets
        targets=$(playbash __complete-targets 2>/dev/null)
        local m
        COMPREPLY=()
        while IFS= read -r m; do
          [[ -n "$m" ]] && COMPREPLY+=( "${prefix}${m}" )
        done < <(compgen -W "$targets" -- "$last")
        compopt -o nospace 2>/dev/null
      fi
      return
      ;;
    run|push|debug)
      # Option values: -n/-p take a number, no completion to offer.
      case "$prev" in
        -n|--lines|-p|--parallel)
          return
          ;;
      esac

      # Count positional args before the cursor (skip subcommand + opt pairs).
      local pos=0
      local skip_next=0
      for ((i = 1; i < COMP_CWORD; i++)); do
        local w="${COMP_WORDS[i]}"
        if [[ "$skip_next" == "1" ]]; then
          skip_next=0
          continue
        fi
        case "$w" in
          run|push|debug) ;;
          -n|--lines|-p|--parallel) skip_next=1 ;;
          -*) ;;
          *) ((pos++)) ;;
        esac
      done

      # Option flag completion takes priority over positional shape.
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-n --lines -p --parallel --self -h --help" -- "$cur") )
        return
      fi

      if [[ $pos -eq 0 ]]; then
        # Playbook name — glob ~/.local/bin/playbash-* and strip the prefix.
        local playbooks=()
        local p
        for p in "$HOME"/.local/bin/playbash-*; do
          [[ -e "$p" ]] || continue
          [[ "$p" == *.js ]] && continue
          playbooks+=( "${p##*/playbash-}" )
        done
        COMPREPLY=( $(compgen -W "${playbooks[*]}" -- "$cur") )
        return
      fi

      if [[ $pos -eq 1 ]]; then
        # Targets — comma-separated host/group/all. Split on the last comma.
        local prefix last
        if [[ "$cur" == *,* ]]; then
          prefix="${cur%,*},"
          last="${cur##*,}"
        else
          prefix=""
          last="$cur"
        fi
        local targets
        targets=$(playbash __complete-targets 2>/dev/null)
        local m
        COMPREPLY=()
        while IFS= read -r m; do
          [[ -n "$m" ]] && COMPREPLY+=( "${prefix}${m}" )
        done < <(compgen -W "$targets" -- "$last")
        # nospace so the user can keep typing ',nexthost'. Trailing space
        # is added manually with a space keypress when the list is done.
        compopt -o nospace 2>/dev/null
        return
      fi
      ;;
  esac
}

complete -F _playbash playbash
