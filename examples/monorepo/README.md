# Monorepo example

Two pnpm workspaces (`@example/greet` and `@example/cli`) with their
tasks generated from a `Package` template.

```sh
pkf list -v
pkf run ci          # install + test:greet + test:cli
pkf run test:cli    # test:greet runs first because the Pkl deps say so
pkf graph --format mermaid     # see the per-package fan-out
```

What this Taskfile demonstrates:

- **One template, many packages.** The `testTask(p, deps)` function
  mints one `Task` per workspace; adding a third package is one extra
  `local pkg = new Package { ... }` plus one `testTask(pkg, ...)`.
- **Cross-package deps as Pkl references.** `testCli` lists `testGreet`
  in its `deps` Listing — when you rename `@example/greet`, the
  reference moves with it; a typo never compiles.
- **`install` is intentionally uncached.** pnpm's `node_modules` is a
  forest of symlinks into a content-addressed store; pkfire's archive
  format only handles regular files and directories, so caching the
  install would leave dangling links on restore. pnpm itself is fast on
  a warm store, so rerunning it costs almost nothing.
- **`workdir = "packages/<id>"`** makes inputs relative to each
  package, matching how monorepo tooling normally addresses files.
