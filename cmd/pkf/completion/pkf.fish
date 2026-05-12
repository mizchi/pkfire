# pkf fish completion.
# Suggested install:  pkf completion fish > ~/.config/fish/completions/pkf.fish

function __pkf_tasks
    pkf list 2>/dev/null | awk '{print $1}'
end

# Subcommands when no subcommand has been picked yet.
complete -c pkf -f -n '__fish_use_subcommand' -a init      -d 'write a starter Taskfile.pkl'
complete -c pkf -f -n '__fish_use_subcommand' -a list      -d 'list declared tasks'
complete -c pkf -f -n '__fish_use_subcommand' -a run       -d 'run one or more tasks'
complete -c pkf -f -n '__fish_use_subcommand' -a up        -d 'supervise long-running services'
complete -c pkf -f -n '__fish_use_subcommand' -a doctor    -d 'diagnose pkfire setup'
complete -c pkf -f -n '__fish_use_subcommand' -a format    -d 'pkl format -w wrapper'
complete -c pkf -f -n '__fish_use_subcommand' -a hooks     -d 'manage .git/hooks shims'
complete -c pkf -f -n '__fish_use_subcommand' -a affected  -d 'run tasks whose inputs changed since <ref>'
complete -c pkf -f -n '__fish_use_subcommand' -a clean     -d 'remove declared outputs'
complete -c pkf -f -n '__fish_use_subcommand' -a cache     -d 'inspect / clean the local CAS'
complete -c pkf -f -n '__fish_use_subcommand' -a completion -d 'emit shell completion script'
complete -c pkf -f -n '__fish_use_subcommand' -a graph     -d 'emit DAG (dot / mermaid / tree)'
complete -c pkf -f -n '__fish_use_subcommand' -a version   -d 'print pkf version'
complete -c pkf -f -n '__fish_use_subcommand' -a help      -d 'show usage'

# Dynamic task names for the subcommands that take them.
complete -c pkf -f -n '__fish_seen_subcommand_from run affected clean up' -a '(__pkf_tasks)'

# Nested subcommand completions.
complete -c pkf -f -n '__fish_seen_subcommand_from hooks' -a 'install uninstall list'
complete -c pkf -f -n '__fish_seen_subcommand_from cache' -a 'stats prune rm clear'
complete -c pkf -f -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
complete -c pkf -f -n '__fish_seen_subcommand_from list' -l color -a 'auto always never'

# `pkf graph --format <TAB>`.
complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l format -a 'dot mermaid tree'
