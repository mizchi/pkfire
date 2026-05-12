#compdef pkf
# pkf zsh completion.
# Suggested install:  pkf completion zsh > "${fpath[1]}/_pkf"
# then `compinit` (re-source ~/.zshrc).

_pkf() {
  local -a subcommands
  subcommands=(
    'init:write a starter Taskfile.pkl'
    'list:list declared tasks'
    'run:run one or more tasks'
    'up:supervise long-running services'
    'doctor:diagnose pkfire setup'
    'lint:detect Taskfile dead code patterns'
    'format:pkl format -w wrapper'
    'hooks:manage .git/hooks shims'
    'affected:run tasks whose inputs changed since <ref>'
    'clean:remove declared outputs'
    'cache:inspect / clean the local CAS'
    'completion:emit shell completion script'
    'graph:emit DAG (dot / mermaid / tree)'
    'version:print pkf version'
    'help:show usage'
  )

  if (( CURRENT == 2 )); then
    _describe 'subcommand' subcommands
    return
  fi

  case "${words[2]}" in
    list)
      if [[ "${words[$((CURRENT-1))]}" == "--color" ]]; then
        _values 'color' auto always never
      fi
      ;;
    run|affected|clean|up)
      local -a tasks
      tasks=(${(f)"$(pkf list 2>/dev/null | awk '{print $1}')"})
      _describe 'task' tasks
      ;;
    hooks)
      if (( CURRENT == 3 )); then
        _values 'hooks subcommand' install uninstall list
      fi
      ;;
    cache)
      if (( CURRENT == 3 )); then
        _values 'cache subcommand' stats prune rm clear
      fi
      ;;
    completion)
      if (( CURRENT == 3 )); then
        _values 'shell' bash zsh fish
      fi
      ;;
    graph)
      if [[ "${words[$((CURRENT-1))]}" == "--format" ]]; then
        _values 'format' dot mermaid tree
      fi
      ;;
  esac
}

_pkf "$@"
