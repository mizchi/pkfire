# Split/import Example

This example keeps one runnable `Taskfile.pkl` at the project root
while splitting task definitions into `tasks/*.pkl` and shared
constants into `shared/*.pkl`.

```sh
pkf list
pkf graph --json --target ci
pkf run ci
```

`tasks/test.pkl` imports `tasks/build.pkl` and declares
`deps { buildTasks.build }`, so cross-file dependencies stay typed
Task references instead of string names.
