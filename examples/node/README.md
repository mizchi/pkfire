# Node example

A minimal Node project using the built-in `node:test` runner — no dev
dependencies, no transpiler, just three files plus the Taskfile.

```sh
pkf list -v
pkf run ci      # check + test + smoke
pkf run test    # leaf: just unit tests (after a syntax check)
pkf run --watch test
```

The Taskfile shows three idioms worth borrowing:

- **`tools { ["node"] = "24" }`** declares the runtime version so the
  action key is invalidated when the team bumps Node — without that,
  `mise` upgrading underneath you would be invisible.
- **`deps { check }`** chains a fast pre-flight (`node --check`) before
  the slower test runner. The two share the same `inputs`, so if only
  the test file changes, `check` is a cache hit and only `test` runs.
- The `smoke` task uses Pkl's hash-quoted string literal (`#"..."#`)
  so the embedded `import("./src/greet.js")` does not need extra
  escaping.
