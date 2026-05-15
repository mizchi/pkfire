# with-pkspec example

A minimal pkfire Taskfile that demonstrates the three pkspec
integration surfaces shipped in pkfire 0.11.0:

| Surface | Where | What it does |
| --- | --- | --- |
| `Task.specRef` | `Taskfile.pkl` | The Task names the spec Scenario it implements. Shown by `pkf describe <task>`. |
| `pkspec:spec=<id>` source markers | inside `cmd` here, but normally inside `.go` / `.ts` / `.md` source files | `pkspec lint --scan` and `pkf affected --with-specs` pick them up. |
| `pkf affected --with-specs` | `pkf` CLI | For a given diff, prints the set of spec ids touched (Task.specRef ∪ markers). |

## Try it

```sh
cd examples/with-pkspec

# Inspect a single task — note the `spec:` row.
pkf describe release

# Machine-readable: filter to tasks that carry a specRef.
pkf list --json | jq '.tasks[] | select(.specRef) | {name, specRef}'

# Simulate a diff that edits the release task's input set
# and prints the spec ids that the change touches.
pkf affected --files=cmd/app/main.go --with-specs

# `--specs-only` pipes one id per line into pkspec:
pkf affected --files=cmd/app/main.go --specs-only | xargs pkspec lint --scan
```

## The other side

pkspec's `examples/pkfire-task-link/` has the matching `Spec.pkl` with
`Implementation { kind = "task"; at = "Taskfile.pkl#release" }`. Run
`pkspec check --strict Spec.pkl` over there with `pkf` on `PATH` to
see the cross-check shell out to `pkf list --json`.
