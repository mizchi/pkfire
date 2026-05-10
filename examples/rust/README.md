# Rust example

A single-binary `greet` crate plus tests, with the full Rust gate
modeled in pkfire (`fmt → clippy → test → build`).

```sh
pkf list -v
pkf run ci          # fmt + clippy + test + build (parallel where possible)
pkf run build       # release binary at target/release/greet
pkf run --watch test
```

What this Taskfile demonstrates:

- **Per-task `tools` declarations** — `cargo` and `rustc` versions feed
  the action key, so a `mise` upgrade or a system rustup change
  invalidates the cache without you remembering to.
- **Output limited to one path** — `outputs { "target/release/greet" }`
  keeps the CAS archive tiny (one ~5 MB file) even though `cargo` itself
  produces hundreds of MB under `target/`. Expand the glob to
  `target/release/**` if you actually need the intermediate artifacts
  cached.
- **No special handling for incremental rebuilds** — pkfire's per-input
  hashing is already file-grained; layering on top of cargo's
  incremental compilation just works.
