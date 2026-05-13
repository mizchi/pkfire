# Diagnostics Example

This example shows the CLI features that help audit and repair a
Taskfile without changing normal task execution.

Useful commands:

```sh
pkf list --long --all --color=never
pkf lint --json
pkf lint --fix --dry-run
pkf doctor --json
pkf doctor --fix --dry-run
pkf explain ci
```

To compare why a task's action key changed:

```sh
cp Taskfile.pkl /tmp/pkfire-diagnostics-old.pkl
# edit Taskfile.pkl
pkf explain --diff /tmp/pkfire-diagnostics-old.pkl ci
```

`doctor --fix` can replace the `pkf` binary found on `PATH`. Keep
`--dry-run` until the plan points at the exact file you intend to
replace.
