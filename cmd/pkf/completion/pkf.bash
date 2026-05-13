# pkf bash completion.
# Source this file, or save into /usr/local/etc/bash_completion.d/.
# Suggested install:  pkf completion bash > ~/.bash_completion.d/pkf
#
# Dynamic task-name completion calls back to `pkf list` (without -v
# so the output is one name per line, prefix-trimmable).

_pkf() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  # First positional = subcommand.
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "init list run up doctor lint format hooks affected clean cache completion graph version help" -- "$cur"))
    return
  fi

  local sub="${COMP_WORDS[1]}"
  case "$sub" in
    list)
      if [[ "$prev" == "--color" ]]; then
        COMPREPLY=($(compgen -W "auto always never" -- "$cur"))
      elif [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-f --file -v --verbose --long --json --all --unsorted --source-order --color" -- "$cur"))
      fi
      ;;
    lint)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-f --file --json --fix --dry-run" -- "$cur"))
      fi
      ;;
    doctor)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-f --file --json --fix --dry-run" -- "$cur"))
      fi
      ;;
    affected)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-f --file --since --files --explain --check --dry-run --no-cache --refresh --timing --quiet --keep-going --profile --watch -j --jobs" -- "$cur"))
        return
      fi
      local tasks
      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
      ;;
    run)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-f --file --watch --dry-run --print-hash --explain-cache --no-cache --refresh --timing --quiet --keep-going --profile --on-fail --remote-only -j --jobs" -- "$cur"))
        return
      fi
      local tasks
      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
      ;;
    clean|up)
      if [[ "$cur" == -* ]]; then return; fi
      local tasks
      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
      ;;
    hooks)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "install uninstall list" -- "$cur"))
      fi
      ;;
    cache)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "stats prune rm clear" -- "$cur"))
      fi
      ;;
    completion)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
      fi
      ;;
    graph)
      if [[ "$prev" == "--format" ]]; then
        COMPREPLY=($(compgen -W "dot mermaid tree json" -- "$cur"))
      elif [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "-f --file --format --json --target --all --unsorted --source-order --depth" -- "$cur"))
      fi
      ;;
  esac
}
complete -F _pkf pkf
