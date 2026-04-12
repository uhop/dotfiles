# playbash bash completion — sourced from ~/.bashrc
_playbash() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local subcommands="run push debug exec put get list hosts log doctor"

  # Find the first subcommand-shaped token. Anything before it is options.
  local subcommand=""
  local i
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      run|push|debug|exec|put|get|list|hosts|log|doctor)
        subcommand="${COMP_WORDS[i]}"
        break
        ;;
    esac
  done

  # No subcommand yet → complete on the subcommand list (or top-level options).
  if [[ -z "$subcommand" ]]; then
    if [[ "$cur" == -* ]]; then
      COMPREPLY=( $(compgen -W "--bash-completion -v --version -h --help" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
    fi
    return
  fi

  case "$subcommand" in
    list|hosts|doctor)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help" -- "$cur") )
      fi
      return
      ;;
    log)
      COMPREPLY=( $(compgen -f -- "$cur") )
      compopt -o filenames 2>/dev/null
      return
      ;;
    put)
      # put <targets> <local-path> [<remote-path>]
      case "$prev" in -p|--parallel) return ;; esac
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-p --parallel --self -N --no-precheck -h --help" -- "$cur") )
        return
      fi
      local pos=0 skip_next=0
      for ((i = 1; i < COMP_CWORD; i++)); do
        local w="${COMP_WORDS[i]}"
        if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
        case "$w" in put) ;; -p|--parallel) skip_next=1 ;; -*) ;; *) ((pos++)) ;; esac
      done
      if [[ $pos -eq 0 ]]; then
        local prefix last
        if [[ "$cur" == *,* ]]; then prefix="${cur%,*},"; last="${cur##*,}"; else prefix=""; last="$cur"; fi
        local targets; targets=$(playbash __complete-targets 2>/dev/null)
        local m; COMPREPLY=()
        while IFS= read -r m; do [[ -n "$m" ]] && COMPREPLY+=( "${prefix}${m}" ); done < <(compgen -W "$targets" -- "$last")
        compopt -o nospace 2>/dev/null
      elif [[ $pos -eq 1 || $pos -eq 2 ]]; then
        # -o filenames so directory matches get a trailing / (no space) and
        # the user can keep tab-completing into the tree.
        COMPREPLY=( $(compgen -f -- "$cur") )
        compopt -o filenames 2>/dev/null
      fi
      return
      ;;
    get)
      # get <targets> <remote-path> [<local-path>]
      case "$prev" in -p|--parallel) return ;; esac
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-p --parallel --self -N --no-precheck -h --help" -- "$cur") )
        return
      fi
      local pos=0 skip_next=0
      for ((i = 1; i < COMP_CWORD; i++)); do
        local w="${COMP_WORDS[i]}"
        if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
        case "$w" in get) ;; -p|--parallel) skip_next=1 ;; -*) ;; *) ((pos++)) ;; esac
      done
      if [[ $pos -eq 0 ]]; then
        local prefix last
        if [[ "$cur" == *,* ]]; then prefix="${cur%,*},"; last="${cur##*,}"; else prefix=""; last="$cur"; fi
        local targets; targets=$(playbash __complete-targets 2>/dev/null)
        local m; COMPREPLY=()
        while IFS= read -r m; do [[ -n "$m" ]] && COMPREPLY+=( "${prefix}${m}" ); done < <(compgen -W "$targets" -- "$last")
        compopt -o nospace 2>/dev/null
      elif [[ $pos -eq 1 || $pos -eq 2 ]]; then
        # pos 1 is the remote path, pos 2 is the local destination. We
        # complete both with the local filesystem: ssh-side completion
        # would need a round trip, and most fleets share enough path
        # structure (~/.config/, /etc/, /var/log/, ...) that the local
        # FS is a useful proxy. Same convention as `put`.
        # -o filenames so directories get a trailing / and tab continues.
        COMPREPLY=( $(compgen -f -- "$cur") )
        compopt -o filenames 2>/dev/null
      fi
      return
      ;;
    exec)
      # exec <targets> <command...> — complete targets at pos 0, then stop.
      case "$prev" in
        -n|--lines|-p|--parallel) return ;;
      esac
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-n --lines -p --parallel --self --sudo -N --no-precheck -h --help" -- "$cur") )
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
    push)
      # push <targets> <script-path> — targets at pos 0, file at pos 1.
      case "$prev" in -n|--lines|-p|--parallel) return ;; esac
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-n --lines -p --parallel --self --sudo -N --no-precheck -h --help" -- "$cur") )
        return
      fi
      local pos=0 skip_next=0
      for ((i = 1; i < COMP_CWORD; i++)); do
        local w="${COMP_WORDS[i]}"
        if [[ "$skip_next" == "1" ]]; then skip_next=0; continue; fi
        case "$w" in push) ;; -n|--lines|-p|--parallel) skip_next=1 ;; -*) ;; *) ((pos++)) ;; esac
      done
      if [[ $pos -eq 0 ]]; then
        local prefix last
        if [[ "$cur" == *,* ]]; then prefix="${cur%,*},"; last="${cur##*,}"; else prefix=""; last="$cur"; fi
        local targets; targets=$(playbash __complete-targets 2>/dev/null)
        local m; COMPREPLY=()
        while IFS= read -r m; do [[ -n "$m" ]] && COMPREPLY+=( "${prefix}${m}" ); done < <(compgen -W "$targets" -- "$last")
        compopt -o nospace 2>/dev/null
      elif [[ $pos -eq 1 ]]; then
        # -o filenames so directory playbooks (mydir/) keep tab-completing.
        COMPREPLY=( $(compgen -f -- "$cur") )
        compopt -o filenames 2>/dev/null
      fi
      return
      ;;
    run|debug)
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
          run|debug) ;;
          -n|--lines|-p|--parallel) skip_next=1 ;;
          -*) ;;
          *) ((pos++)) ;;
        esac
      done

      # Option flag completion takes priority over positional shape.
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-n --lines -p --parallel --self --sudo -N --no-precheck -h --help" -- "$cur") )
        return
      fi

      if [[ $pos -eq 0 ]]; then
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
        compopt -o nospace 2>/dev/null
        return
      fi

      if [[ $pos -eq 1 ]]; then
        # Path containing / → file completion (custom script or directory
        # playbook). -o filenames so directories keep tab-completing.
        if [[ "$cur" == */* ]]; then
          COMPREPLY=( $(compgen -f -- "$cur") )
          compopt -o filenames 2>/dev/null
          return
        fi
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
      ;;
  esac
}

complete -F _playbash playbash
