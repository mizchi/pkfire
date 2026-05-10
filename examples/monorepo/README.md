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
- **`install` is fully cached, symlinks included.** pnpm's
  `node_modules` is a forest of relative symlinks into its
  content-addressed store; pkfire serializes symlink entries as-is and
  validates targets at restore time (relative paths only, resolved
  destination must stay under the cache root). Wiping `node_modules`
  and rerunning `pkf run install` reproduces the entire dependency
  graph without re-running pnpm.
- **`workdir = "packages/<id>"`** makes inputs relative to each
  package, matching how monorepo tooling normally addresses files.
