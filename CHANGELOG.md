# Changelog

All notable changes to pkfire are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Pkl schema version, the `pkf` binary version, and the GitHub
Action version all move together — there is one tag per release
(`pkfire@<version>`) and one row per release in this file.

## [Unreleased]

### Added

- **`pkf run --sandbox` runs an action against only what it declared.**
  `inputs` was a promise nothing checked: a task that reads a file it
  never declared runs fine, caches fine, and then serves a stale hit
  the day that file changes — so the failure surfaces as a wrong build,
  far from the undeclared read that caused it. The sandbox materializes
  exactly the declared inputs, plus the outputs of the actions this one
  depends on, and runs the command there, so the read fails at the
  mistake:

  ```
  $ pkf run --sandbox sneaky
  cat: undeclared/extra.txt: No such file or directory
  pkf: task `sneaky` failed with exit code 1
  ```

  Declared outputs come back into the workspace on success; anything
  else the command wrote is reported and discarded, since an undeclared
  output is usually a missing `outputs` line. A failed action produces
  nothing at all — a command that died half-way has written half an
  output, and containing that is what the sandbox is for.

  This is Bazel's symlink forest, not its namespace sandbox: inputs are
  symlinked, so a large input set costs nothing to materialize and
  absolute paths still resolve. `/usr/bin/cc` and `$HOME/.cargo` are
  still reachable — hermetic *toolchains* are a separate problem, and a
  sandbox that hid `/usr/bin` would fail every task for a reason
  unrelated to its `inputs`. Tasks with no `inputs`, and tasks whose
  `workdir` leaves the repo, run unsandboxed and say so. See #60
  (P1: hermetic sandbox executor).

- **`pkf run -j N` runs actions in parallel.** With an action graph to
  schedule against, `-j` is a ready queue over in-degrees: an action
  starts once everything it depends on has finished, and up to `N` run
  at a time. `-j auto` uses one per available CPU, capped at 16 —
  the number is a limit on *processes*, each of which may be a parallel
  build tool of its own. Sequential stays the default, because raising
  it changes when a Taskfile's side effects happen relative to each
  other and that is the author's call. See #60 (P1: parallel DAG
  scheduler).

  Among ready actions the one earliest in the topological order goes
  first, so `-j 1` is identical to the previous sequential walk and any
  `-j` schedules the same way twice running. With `N > 1` each action's
  output is captured and printed as one block when it finishes, rather
  than streamed and interleaved with three other commands'. A failure
  stops scheduling but does not cancel what is already running:
  cancelling a compiler mid-write leaves a half-written output a later
  run would treat as real.

- **`--timing` reports the critical path.** In parallel the sum of the
  durations exceeds the wall clock and says nothing useful; what
  decides how long the run takes is the longest chain of actions the
  graph required to run in sequence. Durations are now milliseconds
  rather than whole seconds, which a parallel run mostly rounded to
  zero.

  ```
  pkf:   total  1.0s wall
  pkf:   critical path  1.0s  compile -> link -> package
  ```

- **Artifacts are first-class, and the files are the edges.** A
  declared `outputs` pattern makes its task the producer of those
  paths; a task whose `inputs` reach into that region is a consumer,
  and pkfire now derives the edge between them instead of requiring it
  to be written twice. Two things follow:

  - **Order.** In any run containing both, the producer is scheduled
    first. `pkf run size build` runs `build` first when `size` reads
    what `build` declares as output, however the targets were listed.
  - **Key soundness.** The outputs of everything a task depends on are
    hashed into its action key as `consumedArtifacts`. A task that
    declared `deps { build }` but no matching `inputs` line previously
    had a key that could not see a byte `build` wrote, so it stayed a
    cache hit while the artifact it consumed changed underneath it.

  Inference orders and keys the tasks in a run; it does not change
  which tasks a run contains, because pulling in a producer would
  execute a command nobody asked for. `deps` remains how a Taskfile
  says "build this first", and the new `undeclared-artifact-dep` lint
  rule reports where that line is missing. See #60 (P1: target graph
  and action graph, artifacts).

- **`pkf run` now executes an action graph rather than walking
  `deps`.** Analysis lowers the requested targets into
  `ActionGraph` — nodes carrying an `ActionDescriptor`, inputs tagged
  `SourceArtifact` or `GeneratedArtifact`, and edges tagged with why
  they exist — and the runner executes that. Today one task lowers to
  one `SpawnAction`, so the schedule is the same except where an
  artifact edge reorders it; the graph is the seam a rule/provider
  analysis phase and a parallel scheduler plug into.

- **`pkf explain <task>` reports artifact provenance.** Input patterns
  produced by another task are annotated with the producer, an
  `artifacts:` line counts the files hashed in from dependencies, and
  derived edges are listed with the input pattern, the output pattern,
  and a concrete path matching both.

### Changed

- **`pkf lint --fix` / `--dry-run` and `pkf explain --diff` are
  rejected with a reason.** They were accepted and ignored, so
  `pkf lint --fix` printed findings, changed nothing, and exited as if
  it had done the work. `explain --diff` was worse: the flag was
  skipped but the Taskfile it named became a second positional, so the
  error read "too many task names".

- **The action key covers consumed artifacts, invalidating every
  existing entry.** `consumedArtifacts` is a new field of the action
  descriptor, so the IR version moves to `pkfire-action-v2` and no key
  computed by 0.15.0 can match. Run `pkf cache clear` after upgrading.

- **A cycle among tasks is reported by the analysis phase, with its
  reasons.** A cycle needing a derived edge would previously have been
  invisible, and reporting only "cycle" would send the reader looking
  for a `deps` line that does not exist. Each edge in the reported
  cycle now says whether it came from `deps` or from one task reading
  what another declares as output, with a path that matches both
  patterns.

### Fixed

- **`pkf clean --dry-run` removed the outputs it claimed to preview.**
  The flag was accepted and ignored, so the command printed
  `removed: …` and removed them — the one invocation a person reaches
  for precisely because they are not sure what will be deleted. It now
  prints `would remove: …` and touches nothing.

- **The README documented flags that do not exist.** Every `pkf …`
  form in it was run against the binary; nine exited with "unknown
  flag". `list --long` / `--unsorted` / `--color`, `graph --format`
  (DOT, Mermaid) / `--target` / `--depth`, `doctor --fix`,
  `explain --diff` and `lint --fix` were Go-era flags the MoonBit port
  never reimplemented. The README also claimed `pkf graph` emits
  Graphviz DOT (it prints a tree, so the documented
  `pkf graph | dot -Tsvg` pipeline could not have worked) and that
  `format --check` exits 11 (it exits 1). All corrected, with the
  unported flags recorded in the status table rather than quietly
  dropped.

- **The generated shell completions offered flags that error.** All
  three shells advertised the same Go-era set. They now offer only
  what the dispatcher implements, plus `clean --dry-run`.

- **`examples/diagnostics` could not run.** Two of its tasks invoked
  `pkf list --long --all --color=never` and `pkf doctor --fix
  --dry-run`, so `pkf run ci` in that example failed with "unknown
  flag". They now use `pkf list --all --json` and `pkf clean
  --dry-run`.

- **`--keep-going` ran the dependents of a failed task.** It was
  implemented as "carry on down the topological order", so a task whose
  dependency had just failed ran anyway — against inputs that were
  never produced, reporting a second failure that only echoed the
  first, or worse, succeeding on stale files. Anything downstream of a
  failure is now reported as skipped, and independent tasks still run,
  which is what the flag was for:

  ```
  pkf: task `build` failed with exit code 1
  pkf: - test (skipped: `build` failed)
  ```

- **`-f` was lost after a flag that takes a separate value.**
  `pkf run --profile ci -f other/Taskfile.pkl build` read `ci` as the
  first positional and stopped looking for `-f`, which then reached the
  run parser as an unknown flag. Flags whose value is a separate token
  now consume it.

- **A task that exited 0 without its declared outputs exited the
  process.** The diagnostic was right but the mechanism was `exit(1)`
  from inside the task, which under `-j` would strand the other actions
  mid-write. It now reports and returns non-zero, and the run fails the
  same way.

- **`moon check --deny-warn` did not cover `conformance/`.** Both the
  root and dogfood check tasks passed only `src/cmd/pkf src/loader`, so
  deprecations in the conformance member went unnoticed until the
  toolchain turned them into errors. Both now check `conformance/src`
  as well.

## [0.15.0] - 2026-08-29

The local cache was not hitting at all before this release, and fixing
that exposed everything downstream of it: the action key was blind to
several values that change a build, archives were not safe to unpack,
and a failed restore counted as a hit. All of that is fixed here, but
the fixes change behaviour for existing Taskfiles — read "Changed"
below before upgrading.

**Run `pkf cache clear` after upgrading.** The action key covers new
fields, so every entry written by an earlier version is unreachable
and only takes up disk. Entries holding outputs that contain symlinks
or empty directories were also written in a shape this version no
longer produces; they are rejected rather than restored, but clearing
is the cheaper way to get there.

`-j` / `--jobs`, `--watch` and `--on-fail` were parsed as task params
and silently dropped; they now exit with the reason. A run that passed
one of them was never getting the behaviour it asked for.

### Added

- **A canonical action descriptor behind the action key.** The key is
  now a SHA-256 over a length-prefixed serialization of an
  `ActionDescriptor` — mnemonic, executable, argv, effective env,
  `inheritEnv`, inputs with digests, declared outputs, working
  directory, execution platform, and execution properties. Adding a
  field to the key means adding a field to the IR, so a value cannot
  reach the command while staying invisible to the cache. Length
  prefixes make the form injection-proof: a `cmd` containing the
  serializer's own separators cannot forge a neighbouring field.
- **`pkf run` reserved flags now work**: `--dry-run`, `--print-hash`,
  `--explain-cache`, `--no-cache`, `--refresh`, `--remote-only`,
  `--quiet`, `--timing`, `--keep-going`, `--profile=NAME`. Multiple
  targets (`pkf run a b c`) and glob targets (`pkf run 'test:*'`) run
  the topological union. `-j` / `--jobs`, `--watch` and `--on-fail` are
  rejected with the reason rather than ignored — the runner is
  sequential, and `pkf watch` is the watch entry point.
- **`pkf trace <task>`** — discover a task's real inputs by observing
  what it reads, using an `LD_PRELOAD` shim over libc's `open` family
  (the approach [vite-task uses][vite-task]). `--check` audits the
  observed reads against the declared `inputs` and exits non-zero when a
  file is read that no input covers; `--emit` prints an `inputs { … }`
  block matching reality. Linux only; see
  [docs/auto-inputs.md](./docs/auto-inputs.md) for the mechanism and its
  limits.

[vite-task]: https://zenn.dev/herp_inc/articles/strange-task-runner

### Changed

- **A task with no declared `inputs` is no longer cached.** Its action
  key depends on nothing a user can edit, so with the cache-hit bug
  fixed the first run would have stored an entry and every run after it
  would have been a permanent hit — a git hook task installed by
  `pkf hooks install` would have fired exactly once. `cache` still
  defaults to `true`; declaring `inputs` is what opts a task into it.
- **A task that exits 0 without producing its declared `outputs` now
  fails.** Previously it published an empty cache entry, which a later
  run restored over a working tree. A task whose literal `outputs` are
  aspirational rather than real needs them removed or `cache = false`.
- **Every existing cache entry is invalidated.** The action key is now
  a digest over a canonical descriptor covering `defaults.env`,
  `inheritEnv`, the declared outputs, the workdir and the execution
  platform — none of which it saw before — so no key computed by an
  earlier version can match.
- **`pkf doctor` reports what the cache actually costs.** The cache row
  counted top-level CAS shards — a number between 0 and 256 that says
  nothing about disk use — so it could not answer the one question it
  exists for. It now aggregates size and entry count the same way
  `pkf cache stats` does, and turns `WARN` with a prune hint past a
  threshold:

  ```
  WARN  cache  ~/.cache/pkfire-mbt (612.4 MB across 2103 entries)
        consider `pkf cache prune --older-than=30d` or `pkf cache clear`
  ```

  Defaults are 500 MB and 2000 entries, overridable per machine with
  `PKFIRE_MBT_CACHE_WARN_BYTES` / `PKFIRE_MBT_CACHE_WARN_ENTRIES`; a
  malformed value falls back to the default rather than breaking
  `doctor`. Multi-line check messages now indent their continuation
  under the message column instead of breaking the table.

- **`mizchi/pkl` 0.6.0 → 0.7.0, and the `mizchi/cst` workaround is
  gone.** The broken `cst@0.1.7` reached pkfire through `pkl@0.6.0`,
  which pinned it; pkfire could only force the resolver upward by
  declaring `mizchi/cst@0.1.9` as a direct dependency of its own — a
  constraint on a package pkfire does not itself use. `pkl@0.7.0` pins
  `cst@0.1.10`, so the direct dependency is dropped and the transitive
  graph is correct on its own.

### Fixed

- **The cache silently reshaped output trees containing symlinks or
  empty directories.** The output walker followed symlinks and only ever
  stored regular files, so a round-trip through the cache rewrote what
  the task had produced: a symlink came back as a *copy* of its target,
  an empty directory vanished, and a link pointing back up the tree
  (`out/loop -> ..`) was followed until the OS path-length limit stopped
  it — one 3-byte output expanded to 121 archive members and 216 KB, and
  swept in files from outside the declared outputs. The walker now uses
  `lstat` and records symlinks and empty directories as their own
  archive members (tar typeflags `2` and `5`, with the GNU `K`
  extension for long link targets) instead of following them. The same
  case is now 2 members and 4 KB, and restores byte-for-byte.
- **Symlink members are validated before restore.** Adding symlinks to
  an archive format that unpacks untrusted remote entries reopens tar
  path traversal from the other side: a member *name* can be safe while
  its link *target* points anywhere, and a later member writing through
  that link lands outside the workspace. Targets are now resolved
  lexically against the link's own directory and rejected if they leave
  the restore root, which — like every other archive rejection — falls
  through to executing the action.
- **`pkf cache --help` printed "unknown cache subcommand".** `--help`,
  `-h` and `help` now reach the usage block, matching what `pkf` itself
  does at the top level. A genuine typo still errors as before.
- **The local cache never hit.** `cache_hit` probed for a `manifest`
  file, but the entry format has been a single `entry.tar.gz` blob since
  the archive rewrite, so a freshly stored entry missed on the next run
  and a remote hit was re-fetched every time. The probe now checks the
  file that is actually written, and validates its gzip magic so a
  half-written blob reads as a miss.
- **A failed restore counted as a cache hit.** `cache_restore` swallowed
  every error and returned `Unit`, so a corrupt or unreadable entry left
  the task reported as "cache hit" with nothing restored. It now returns
  whether it succeeded, and a failure falls through to executing the
  action.
- **Runner flags were silently ignored.** `parse_run_args` only
  understood a single target, named task params, and positionals; every
  documented runner flag fell through into the task-param map and was
  dropped. `pkf run --dry-run deploy` deployed. Reserved flags are now
  parsed by the runner, and an unknown `--flag` that is not a param the
  target declares is an error rather than a silent default.
- **A typo'd param ran the task anyway.** `--verison=1.2.3` was
  discarded and the task ran with the declared default for `version`.
  Unknown params are now rejected.
- **The action key was blind to values that change the build.** It
  covered `cmd`, shell, `task.env`, `tools`, inputs, params and
  positionals — but not the module-level `defaults.env` (which is handed
  to the command), `inheritEnv`, the declared `outputs`, the workdir, or
  the execution platform. Two actions that produce different results
  could share an entry. See "Added: action descriptor" below.
- **Cache archives were not safe to unpack.** Entry names over the
  100-byte ustar limit were silently truncated (restoring a deep output
  to the wrong path); header checksums were not verified and a malformed
  archive returned the members read so far, indistinguishable from a
  complete one; a remote entry could carry an absolute or `../` path and
  write outside the workspace; there was no cap on the expanded size;
  and entries were written in place rather than published by rename.
  All six are fixed — long names use a GNU `LongLink` member, checksums
  are verified, escaping paths and oversized expansions are rejected,
  and every entry is published by an atomic rename.
- **`quiet = true` on a task did nothing.** The schema field and the
  README described suppressing pkfire's per-task diagnostic lines, but
  the runner never read it. It now does, and `pkf run --quiet` does the
  same for a whole run.
- **The build was broken against the current MoonBit toolchain.**
  `mizchi/cst@0.1.7` imports `moonbitlang/core/immut/array`, which the
  core library has replaced with `immut/vector`, and
  `moonbitlang/x@0.4.47` binds a runtime symbol that was renamed. Both
  dependencies are bumped, and the deprecated `@sys` env / `StringBuilder`
  APIs are migrated so `moon check --deny-warn` passes again.
- **Two loader tests shared one package cache directory.** The
  `download_package_uri_to_cache` tests both wrote to `p/n@1.0.0`, and
  the isolation they appeared to have was illusory:
  `PKL_MBT_PACKAGE_CACHE` is process-global, so the per-test cache roots
  are last-writer-wins and after a full run only one of them exists —
  every test's package lands inside it. The success test and the
  sha256-mismatch test therefore shared a directory, which is what made
  the suite fail intermittently under load. Each test now uses a
  distinct package path in its `package://` URI, so they cannot collide
  whichever root wins or whatever order they run in.
- **Every evaluation error in a Taskfile was reported as
  "Taskfile output has no `tasks` mapping".** A typo'd identifier, an
  unknown method, or a task listed in `tasks { … }` but never defined
  all produced that one message, pointing the reader at the `tasks`
  declaration — the part of the file that is almost always fine. It also
  quietly undercut the schema's own selling point, that misspelling a
  dependency fails at evaluation time: it does, but the message named
  the wrong thing. The embedded evaluator renders a member it cannot
  evaluate as `null` rather than reporting a diagnostic, so pkfire now
  recognises `tasks: null` as a failed evaluation, says so, and points
  at `pkl eval <taskfile>` for the exact line and column. Missing and
  wrong-typed `tasks` are reported as themselves. Syntax errors were
  already reported correctly and are unchanged. See #65 for the
  upstream half.

## [0.14.2] - 2026-08-03

### Changed

- **The MoonBit Pkl runtime dependency now uses `mizchi/pkl` 0.6.0.** Root and
  conformance packages share the newer evaluator and parser implementation.

## [0.14.1] - 2026-08-01

### Added

- **Homebrew installation for Apple Silicon macOS.** The repository now ships
  `Formula/pkf.rb`, installs the Pkl CLI as a dependency, validates the formula
  in macOS CI, and synchronizes its release checksum alongside the Nix pin.

### Changed

- **Development, packaging, and CI dependencies are current.** MoonBit uses
  `moonbitlang/x` 0.4.47, the setup Action installs Pkl 0.32.1, the Nix flake
  tracks NixOS 26.05 and the latest MoonBit overlay, GitHub workflows use the
  current action majors, and the remote-cache Worker uses workers-types 5,
  TypeScript 7, and Wrangler 4.

## [0.13.0] - 2026-07-30

### Added

- **`pkf lint` and `pkf watch` now detect task-graph watch loops before they
  spin.** A product-automaton glob solver proves intersections across literals,
  `*`, `**`, `?`, character classes, and brace alternatives while producing a
  concrete witness path. The analyzer reports self output loops, local-cache
  loops, and cross-task strongly connected components; `pkf watch` refuses to
  start when any such cycle is present.
- **Watch-cycle coverage now includes 20 focused tests plus a bounded
  adversarial corpus.** The corpus cross-checks 20 patterns over 1,110 paths,
  while graph tests cover self loops, disjoint and three-task SCCs, duplicate
  declarations, exclusions, workdirs, cache regions, and path normalization.

### Changed

- **Watch inputs and outputs are resolved consistently from each task's
  `workdir`.** Affected-task matching, action-key input hashing, watch analysis,
  and output archive paths now use the same repo-relative contract.
- **MoonBit and embedded Pkl dependencies track the current warning-clean
  toolchain.** `mizchi/pkl` moves to 0.3.4, `mizchi/x` to 0.5.2, and
  `moonbitlang/async` to 0.20.3.

### Fixed

- **Watcher exclusions match complete path segments.** `.git`, `.cache`,
  `_build`, `node_modules`, and `target` remain ignored without accidentally
  hiding visible names such as `.gitignore`, `_builder`, or `targeted`.
- **Excluded first-choice glob witnesses no longer hide a visible
  intersection.** The solver continues through alternative characters and
  brace branches instead of treating an excluded candidate as proof that no
  actionable overlap exists.
- **Latest MoonBit warnings are removed instead of suppressed.** Conformance
  and loader code use current error handling, collection construction, string,
  and package APIs, and all active packages pass `moon check --deny-warn`.

## [0.12.4] - 2026-07-15

### Changed

- **MoonBit manifests and dependencies now track the current toolchain.** Root
  and conformance use the `moon.mod` / `moon.pkg` DSL under a two-member
  `moon.work`; direct dependencies move to `mizchi/pkl` 0.3.3,
  `mizchi/fswatch` 0.2.1, `mizchi/x` 0.5.1, `mizchi/zlib` 0.4.8,
  `moonbitlang/async` 0.20.2, and `moonbitlang/x` 0.4.46. CI now enforces
  `moon check --deny-warn`. There is no Taskfile schema or CLI behavior change.
- **The bundled pkfire skill is now an implementation-backed executable
  specification for `pkf`.** The concise entry point routes agents to schema,
  runtime, and CLI references; it also distinguishes the current MoonBit
  behavior from stale Go-era flags and documents known compatibility gaps.

### Fixed

- **Active build, CI, conformance, and release scripts now use the
  workspace-qualified MoonBit binary path.** After introducing `moon.work`,
  the executable is emitted under `build/mizchi/pkf/src/cmd/pkf/pkf.exe`;
  the old unqualified path could silently select a stale local artifact and
  fails on a clean checkout.

## [0.12.3] - 2026-06-27

### Fixed

- **secretlint pre-push hook no longer collapses the file list into one path.**
  Recipe 14 (`14-secretlint-pre-push.pkl`) captured the NUL-separated `git
  ls-files -z` / `git diff -z` output in `files=$(...)`, but bash command
  substitution strips NUL bytes — every path concatenated into one giant
  argument and `secretlint` died with `ENAMETOOLONG`, most reliably on the
  first push of a new branch. The list is now piped straight into `xargs -0`.

## [0.12.2] - 2026-06-27

### Changed

- **MoonBit-first repo layout.** The MoonBit project moved from `pkf-mbt/`
  to the repo root and the moon module was renamed `mizchi/pkf-mbt` →
  `mizchi/pkf`. No CLI/behavior change.

### Fixed

- **`nix run github:mizchi/pkfire/v<ver>` now resolves the matching
  release.** The Release workflow points the `v<ver>`/`v<major>` tags at the
  commit carrying the sha256-synced `nix/pkf-release.json`, so the binary-fetch
  flake no longer serves the previous release when pinned by tag.

## [0.12.1] - 2026-06-26

### Fixed

- **Taskfiles that name a task `default` evaluate again.** A bare `default`
  identifier referenced in an object body (e.g. `local default: Task = ...`
  then `tasks { default }`) was mis-parsed by the embedded Pkl evaluator as the
  collection-default keyword and failed with `unsupported expression`. Fixed in
  `mizchi/pkl` 0.2.7 (bumped 0.2.4 → 0.2.7, which also pulls the pkspec-era
  evaluator fixes: cyclic-detection, cross-module type resolution, late-binding).

## [0.12.0] - 2026-06-24

### Changed

- **`pkf` is now a MoonBit binary.** The Go implementation
  (`cmd/pkf/` + `internal/`) and the Go conformance harness have been
  removed; the repo contains zero Go. The CLI contract (JSON shapes,
  exit codes, env, Pkl schema, side effects) is unchanged — verified
  by the MoonBit-native conformance runner (41/41 against the frozen
  goldens). The Pkl evaluator is embedded (no `mpkl` subprocess).
- Distribution: prebuilt binaries for `linux-amd64`, `linux-arm64`,
  and `darwin-arm64`. The Nix flake builds from the MoonBit sources.

### Removed

- The `go install github.com/mizchi/pkfire/cmd/pkf` acquisition
  channel. Use the prebuilt release binary, the Nix flake, or the
  GitHub Action.
- Intel macOS (`darwin-amd64`) binaries — the MoonBit toolchain has no
  x86_64 macOS build.

## [0.11.0] - 2026-06-22

### Added

- `pkf describe <task>` and `pkf run <task> --help` / `-h` print
  desc / params / inputs / outputs / cache / deps / dependents for
  a single task. `--json` form for tooling. Closes #11.
- Top-level `pkf cache --help` / `-h` / `help` now prints the cache
  usage block instead of erroring with "unknown subcommand". Every
  other subcommand — `init`, `list`, `describe`, `run`, `up`,
  `doctor`, `lint`, `format`, `hooks`, `affected`, `clean`,
  `completion`, `graph`, `explain`, `migrate`, `pkl-cache` — ships a
  dedicated usage block reachable via `pkf <sub> -h`. Closes #12.
- `pkf info` prints a one-shot Taskfile snapshot — path, schema
  version (extracted from the `amends` URI), defaults, every visible
  task, every workflowTest — as either a plain-text summary or
  `--json` for downstream doc / report generators.
- pkfire ↔ pkspec linking surfaces. `Task.specRef: String?` declares
  which Scenario a Task implements; `pkf affected --with-specs` cross-
  references the affected task set against pkspec Scenarios; recipes
  17–19 (pkspec-checks, pkspec-check-pre-push, spec-task-link)
  document the integration. The pkspec side ships
  `Implementation kind = "task"` and `pkspec check --strict` cross-
  validates the Taskfile path / task name.
- `skills/pkfire/assets/recipes/16-release-version-bump.pkl` recipe.
  `pkf run bump-version --from=X --to=Y [--commit=true]` sed-rewrites
  a pinned file list (flake.nix, action.yml, README, docs/quick-
  start.md, …) so the release-tag prelude collapses to one command.
  Portable between BSD and GNU sed. Closes #13.

### Changed

- `pkf doctor` elevates the cache row to `WARN` and recommends
  `pkf cache prune` once cache size or entry count crosses
  configurable thresholds. Tunable via `PKFIRE_CACHE_WARN_SIZE_MB`
  (default 500) and `PKFIRE_CACHE_WARN_ENTRIES` (default 2000); set
  either to 0 to disable. Closes #14.
- Examples now amend the published `pkfire@0.10.0` Pkl package.

### Fixed

- `writeArchive` previously passed each output pattern through
  `filepath.Join` + `os.Lstat` as if it were a literal path. Glob
  patterns like `js/dist/**` resolved to nonexistent literal paths,
  silently skipped via the `ErrNotExist` branch, and the resulting
  cache archive was empty. Subsequent runs hit the cache entry,
  restored an empty archive, and any downstream task needing the
  missing artifacts failed with ENOENT. The archive walker now
  expands globs via `doublestar.Glob` before staging files. Closes
  #15.

## [0.10.0] - 2026-05-14

### Added

- `pkf affected --files <path>` simulates changed files without
  consulting git, and `--explain` reports the matching input patterns
  plus direct/dependent affected tasks.
- Taskfiles can declare `workflowTests { ... }`; `pkf affected --check`
  validates file-change expectations against the affected run plan.
- `pkf explain <task>` now includes declared deps, dependents, input
  patterns, outputs, and upstream affected trigger patterns.
- `pkf list --json` and `pkf graph --json` emit machine-readable task
  metadata, including aggregate/service kind, deps, inputs, outputs,
  cache state, workdir, params, and service metadata.
- `pkf run --explain-cache <task>` explains per-task action keys,
  hit/miss/forced-run decisions, local cache lookup paths, matched
  inputs, unmatched globs, broad input patterns, invocation overlays,
  and no-output cache notes.
- `pkf lint` now emits warning-level cache diagnostics for tasks with
  inputs but `cache = false`, and for build-like cacheable tasks that
  declare no outputs.
- Added `examples/split-import`, showing a single root Taskfile that
  imports task fragments under `tasks/`, shared constants under
  `shared/`, typed cross-file deps, and a deps-only aggregate.
- Added Pkl contract tests for the split/import example so the
  documented fragment convention is imported and validated directly.
- The repo's own `preflight` now runs `test:workflow` to dogfood
  `workflowTests`.

### Changed

- Examples now amend the published `pkfire@0.9.0` Pkl package.
- Shell completions now include the late-added `explain`, `migrate`,
  and `pkl-cache` commands and their core options.
- The repo's `test:examples` task now also runs example contract tests.

## [0.9.0] - 2026-05-13

### Added

- `pkf explain --diff OLD_TASKFILE <task>` compares the action-key
  inputs for the current Taskfile against another Taskfile and reports
  which component changed (`cmd`, `shell`, `shellFlags`, `env`,
  `tools`, input file digests, or config hash).
- `pkf lint` now also flags suspicious rendered tasks: cacheable
  outputs with no inputs, services without a readiness probe, and
  tasks that have neither `cmd` nor `deps`.
- `pkf list --long` prints a compact audit table with visibility,
  cache/quiet state, deps, input/output counts, shell, flags, and cmd.
- `pkf lint --json` emits structured findings for editor/CI consumers.
- `pkf doctor` now checks whether `pkf` on `PATH` differs from the
  currently running binary, which helps catch stale hook installations.
- `pkf doctor --json` emits structured setup checks, and
  `pkf doctor --fix --dry-run` previews replacing a stale `pkf` on
  `PATH` with the currently running binary. Without `--dry-run`, the
  old binary is backed up before replacement.
- `pkf lint --fix` safely adds `cache = false` to tasks that declare
  outputs but no inputs; other lint findings remain suggestions.
- Added `examples/diagnostics` and recipe 15 to show diagnostics,
  machine-readable lint/doctor output, safe fix previews, internal
  audit tasks, quiet wrappers, and strict shell flags.
- The repo's own `Taskfile.pkl` now exposes `fmt` and `fmt:check`
  maintenance tasks, and `preflight` depends on the formatting check.

## [0.8.0] - 2026-05-13

### Added

- `Task.cmd` can be omitted for deps-only umbrella tasks. The
  rendered task succeeds after its dependencies complete without
  spawning a shell, so `ci` / `all` aggregators no longer need
  `cmd = ":"`.
- `Task.shellFlags` configures the arguments passed before `cmd`
  (default `List("-c")`). This keeps existing shell behavior while
  allowing strict bash flags or runtimes such as Node via
  `shellFlags = List("-e")`.
- `Task.quiet = true` suppresses pkfire's per-task diagnostic lines
  for that task while preserving the task's own stdout/stderr and the
  final run summary.

## [0.7.0] - 2026-05-13

### Added

- `pkf run -- args...` now forwards tail args to the `default`
  task when no explicit task name is given.
- `pkf list --unsorted` / `pkf graph --unsorted` preserve
  Taskfile declaration order, and `pkf list` aligns description
  columns.
- `Task.visibility = "internal"` hides helper tasks from
  `pkf list` / `pkf graph` by default; `--all` reveals them.
- `pkf list --color=auto|always|never` adds optional ANSI color
  to human-readable list output.
- `pkf graph --format tree` emits a terminal-readable dependency
  tree with `--target` and `--depth=N` support.
- `pkf lint` detects local `Task` definitions in the current
  Taskfile that are not rendered through `tasks { ... }`.

## [0.6.0] - 2026-05-11

Pkl schema is unchanged from 0.4.0 / 0.5.0 — this release ships
the second wave of `pkf` CLI features and runtime behavior on top
of the same schema surface. Existing Taskfiles keep working; the
`amends` URI bump is mechanical.

### Added

- **`pkf <plugin> <args>` plugin dispatch.** When `args[0]` isn't a
  built-in subcommand, pkfire looks for `pkf-<args[0]>` on PATH
  and execs it with the remaining args. Plugin inherits the
  user's terminal (stdin/stdout/stderr); `PKF_PLUGIN_NAME` env
  carries the invoked subcommand. Git-style extension point —
  write `pkf-release` once, call `pkf release`. No registration.
- **`pkf run --remote-only` (also `pkf affected`).** Skips the
  local CAS entirely; reads + writes go straight to the remote
  cache configured via `PKFIRE_REMOTE_CACHE`. Useful for "did
  my last build actually push to remote?" smoke tests in CI.
  Requires the env var; errors clearly if it's not set.
- **`pkf graph --target X --depth=N`.** Limits BFS depth from
  the target so the rendered graph stays a localized
  neighborhood instead of the full transitive subgraph. Pair
  with `--format mermaid` for inline-renderable comment
  artifacts.
- **`pkf migrate --to=<ver>`.** Rewrites a Taskfile.pkl's
  `amends "...pkfire@<old>"` URI to a new version, then
  re-evaluates the file to verify the new schema actually
  loads. If `pkl eval` fails post-migration, the file is
  reverted to the original. `--dry-run` shows the diff
  without writing. `--skip-verify` bypasses the eval check
  (e.g. when pkl isn't on PATH).
- **`pkf pkl-cache warm`.** Pre-evaluates one or more Pkl
  files (default: the discovered Taskfile.pkl) so
  `~/.pkl/cache` is populated. CI prefetch step — runs once
  before parallel jobs so each later `pkl eval` / `pkf run`
  hits a populated cache instead of racing on the same
  fetch.
- **`pkf affected --watch`.** Watch loop that re-evaluates the
  affected set on every file change. The set itself can shift
  (a new edit pulls in different tasks), so each iteration
  re-runs `git diff`, recomputes the affected closure, builds
  a fresh plan, and executes. Watch targets cover every
  task's expanded inputs (broader than a single subgraph) so
  changes anywhere in the repo are noticed.
- **`gitChangedFiles` now unions committed + staged + working-
  tree edits.** Previously `pkf affected --since=<ref>` only
  saw committed-to-HEAD changes; uncommitted edits during local
  iteration didn't trigger affected tasks. The union covers
  all three diff modes, dedupes via map. CI-only flows where
  the working tree is clean still work the same.
- **`pkf run --profile=<name>` (also `pkf affected`).** Run-wide
  profile tag injected as `$PKF_PROFILE` so `cmd` can branch
  (`if [ "$PKF_PROFILE" = "ci" ]; then ...; fi`). Folded into
  every task's action key, so distinct profiles cache as
  distinct entries — `pkf run --profile=ci` and
  `--profile=dev` never share a cache slot even when every
  declared field is otherwise identical.
- **`pkf run --on-fail=shell`.** After a non-zero run, drop into
  `$SHELL` (or `/bin/bash`) in the first-failed task's
  resolved workdir, with `PKF_TASK_NAME` / `PKF_TASK_ROOT` /
  `PKF_WORKSPACE_ROOT` / `PKF_PROFILE` populated. `exit` returns
  to pkf with the original exit code. Doesn't reconstruct the
  failed task's full declared env (use `pkf explain <task>` from
  inside the shell to see it) — just enough context to poke
  around at the workdir.
- **`pkf run --keep-going` (also wired into `pkf affected`).**
  Bazel `-k` / make `-k` semantics: a failure in one subgraph
  doesn't cancel other independent subgraphs. Transitive
  downstreams of a failed task still skip (`OutcomeSkipped`).
  Execute aggregates failures via `errors.Join` so the caller
  sees every error, not just the first.
- **`pkf explain <task>`.** Dumps every input to the action
  key: cmd, shell, sorted env, sorted tools, every expanded
  input file with its content-hash prefix, the Pkl module's
  config hash, plus `acceptsArgs` / `params` declarations.
  Diagnostic for the recurring question "why isn't this hitting
  cache?" — diff two runs' `pkf explain <task>` outputs to see
  exactly which component flipped.
- **Auto-injected env vars `PKF_TASK_NAME` / `PKF_TASK_ROOT` /
  `PKF_WORKSPACE_ROOT`.** Every task's `cmd` now sees these
  three so it can reference its own context without hardcoding
  paths. Not part of the action key (they're constants of the
  task definition, already implicit via cmd / env / inputs).
- **`pkf completion <bash|zsh|fish>`.** Emit a shell-completion
  script to stdout. Dynamic task-name completion for `run` /
  `affected` / `clean` / `up` calls back into `pkf list` at
  completion time, so it always reflects the current Taskfile.
  Static subcommand lists for `hooks` / `cache` / `completion`
  / `graph --format`. Install with:
  ```sh
  pkf completion bash > ~/.bash_completion.d/pkf
  pkf completion zsh > "${fpath[1]}/_pkf"
  pkf completion fish > ~/.config/fish/completions/pkf.fish
  ```
- **`pkf run --quiet`.** Suppress per-task log lines
  (`[pkf] <task>: <cmd>` and `[pkf] <task>: hit/ran/...`).
  Errors and the end-of-run summary still print. Useful for CI
  logs and for invoking pkfire from another runner where the
  outer log already labels each step. Also wired into
  `pkf affected`.
- **`pkf clean [task...]`.** Remove tasks' declared `outputs`
  (resolved relative to each task's `workdir`). With no
  positional arg, cleans every task that declares outputs.
  `--dry-run` prints the paths without removing. Cache is
  intentionally untouched — use `pkf cache rm <key>` (or
  `pkf run --refresh`) to invalidate the cached result too.
  Glob targets (`pkf clean 'build:*'`) expand against the
  task list, same as `pkf run` / `pkf affected`.
- **Glob targets for `pkf run` / `pkf affected` / `pkf clean`.**
  Any target containing `*` or `?` is treated as a `path.Match`
  pattern and expanded against task names. So `pkf run
  'test:*'` runs every test-prefixed task in topological
  order. Literal (`*`-free) names pass through unchanged; a
  pattern that matches nothing falls through as the literal
  task name so the existing "unknown task" error surfaces.
- **`pkf cache <stats|prune|rm|clear>`.** Direct control over
  the local CAS at `$PKFIRE_CACHE_DIR` (default
  `$XDG_CACHE_HOME/pkfire`).
  - `stats` — entry count, total size, oldest/newest mtime.
  - `prune [--older-than=Nd]` (default 30d) — drop entries
    whose newest file mtime is older than the threshold.
    `--dry-run` previews. Accepts `Nd` (days),
    `Nh`, `Nm`, `Ns` durations.
  - `rm <action-key>...` — drop specific entries. Accepts
    full 64-char hex or any ≥ 2-char unique prefix.
  - `clear --yes` — nuke the entire `cas/` directory.
    Refuses without `--yes` so accidents stay rare.
- **Auto-generated GitHub Release notes from CHANGELOG.md.**
  The Release workflow now runs `scripts/release-notes.sh
  <version>` and feeds the section between `## [<version>]` and
  the next `## [...]` into `gh release create --notes-file`.
  Re-running the workflow on an existing tag (`workflow_dispatch`)
  also `gh release edit --notes-file` — so a CHANGELOG edit can
  be republished without recreating the release. Falls back to a
  terse default body when the section is missing. Self-tested by
  `pkf run test:release-notes` (wired into `preflight`).

## [0.5.0] - 2026-05-11

Pkl schema is unchanged from 0.4.0 — bumping in lockstep with the
binary/action per project convention. The amends URI change is
mechanical; no Taskfile rewrites needed.

The headline of 0.5.0 is the new **task-runner UX layer**: a
monorepo-aware `pkf affected` for CI, multi-target / default-task
ergonomics, cache-state preview in dry-run, end-of-run timing
summary, plus opt-in git-hook installation. Everything below
sits on top of the unchanged 0.4 schema.

### Added

- **`pkf affected --since=<ref>`.** Monorepo-CI killer: runs only
  tasks whose declared `inputs` glob matches a file in the
  asymmetric diff `<ref>...HEAD`, plus their transitive
  *dependents* in the deps DAG. The unaffected deps that come
  along in the resulting plan hit cache, so the actual work is
  minimal. Default ref is `origin/main` (fallback `origin/master`,
  then `HEAD~1`). Optional positional task names filter the
  affected set: `pkf affected --since=origin/main test:unit
  test:integration` restricts to those exact targets. `--dry-run`
  prints the plan with the same cache-prediction format the
  built-in `pkf run --dry-run` uses.
- **Multi-target `pkf run`.** `pkf run a b c` computes the
  topological union of the targets' subgraphs and runs once. Tail
  args / `--param=` are rejected with multi-target (which target
  would they apply to?) — single-target run keeps the existing
  invocation overlay.
- **Default task.** `pkf run` with no positional argument now
  invokes a task named `default` if one is declared. Errors with
  a `try pkf list` hint when neither a target nor a `default` task
  exists.
- **End-of-run summary + `--timing`.** Every non-watch `pkf run`
  / `pkf affected` now prints a one-line summary at the end:
  `[pkf] done: 6 tasks · 3 hit · 3 ran · 2 uncached (11.3s wall,
  12.0s CPU)`. Adding `--timing` follows with a per-task
  duration breakdown sorted descending — pinpoints the slow task
  without a profiler.
- **`pkf run --dry-run` previews cache state per task.** The
  output is a compact table with one row per task and a status
  column: `hit` (cache lookup will succeed → restore from CAS),
  `will run` (cacheable but no entry yet), `uncached`
  (`cache = false`), `service` (skipped by `pkf run` — preview
  only). Includes the 12-char action key prefix per row, a
  summary line, and a per-invocation overlay note (resolved
  params + tail args) when applicable. With `--no-cache` or
  `--refresh`, the lookup is treated as inert and every
  cacheable task shows `will run` — answers "what would
  `--refresh` actually re-run?". Remote cache is not consulted
  during dry-run to keep it fast.
- **`pkf hooks install` / `uninstall` / `list`.** Convention-based
  git hook manager: any task whose `name` matches a git client-side
  hook event (`pre-commit`, `pre-push`, `commit-msg`, ... full list
  in SKILL.md) becomes installable. Install writes
  `.git/hooks/<event>` as a 3-line shim that delegates to
  `pkf run <event> -- "$@"` (the trailing `$@` carries git's
  per-hook args). The shim is marked so uninstall removes only
  pkfire-managed hooks and won't clobber hand-written ones (use
  `--force` to overwrite). Designed to compose with — not replace —
  dedicated managers like [hk](https://hk.jdx.dev/) and lefthook.
- **`.envrc`-safe idempotent `pkf hooks install`.** Silent
  (zero stdout/stderr) when every shim is already present and
  bit-identical to what pkfire would write — safe to drop into
  `.envrc` for auto-install on `cd`. Writes go through tempfile
  + rename so concurrent reloads can't tear the shim.
- **Recipe 14: secretlint as a pkfire pre-push hook.** A
  copy-paste path for repos whose ONLY git hook concern is
  secrets-scanning: `pnpm add -D secretlint` + a 7-line
  `.secretlintrc.json` + this recipe + `pkf hooks install` = done,
  no prek / `.pre-commit-config.yaml`. Wires to pre-push (not
  pre-commit) so secretlint runs once per push instead of every
  micro-commit; scopes to the outgoing diff via `git diff
  '@{push}..HEAD'`. Composes with prek for projects that
  already use it.
- **GitHub Action friendly `v<ver>` + floating `v<major>` tags.**
  Release workflow now pushes `v0.5.0` and (refreshes) `v0` so
  consumers can write `uses: mizchi/pkfire@v0.5.0` (or `@v0`)
  without tripping GHA's `<repo>@<ref-with-@>` parse failure
  (kawaz/pkf-tasks DR-0004). Dedicated `v-tags.yml` workflow
  fires on Release-success via `workflow_run`, with manual
  recovery via `workflow_dispatch`. Implemented with git CLI
  rather than `gh api` because `git/refs` returned 403 from
  github-actions[bot] even with `Contents: write`. Backfill is
  intentionally skipped: the bot can't push refs whose commit
  contains workflow files different from `main` (no
  `workflows` permission on GITHUB_TOKEN), and old release
  commits trip that hook.
- **`pkf format` (alias for `pkl format`).** Defaults to the
  directory of the discovered Taskfile; `--check` maps to
  `--diff-name-only` (exit 11 on violations). No corresponding
  Taskfile wrapper task — the CLI is the canonical entry point.
- **`pkf doctor`.** Read-only diagnostic. Reports the `pkl` CLI
  version, cache dir + total size, remote-cache reachability
  when configured, and the resolved Taskfile + its `amends`
  line. Exits non-zero iff any check FAILed.
- **`pkf list --json`.** Machine-readable enumeration with every
  Task field for editor/CI tooling that wants to discover tasks
  without parsing the human-readable list.
- **`pkf run --refresh`.** Skip cache *lookup* but still *store*
  the result. Distinct from `--no-cache` (which disables both).
  Use when an undeclared dependency changed and you want to
  re-baseline rather than run uncached forever. Mutually
  exclusive with `--no-cache`.
- **Repo-root `Taskfile.pkl` for project maintenance.**
  Dogfoods pkfire on its own development flow. Tasks: `vet`,
  `test:go`, `test:race`, `test:pkl`, `test:examples`,
  `check-version`, `bump --to=<ver>`, `tag`, `preflight`
  (pre-commit gate aggregating vet + go/pkl/examples tests +
  version + format check). The cross-compile / release matrix
  stays in `examples/dogfood/Taskfile.pkl` (CI gate).
- **`test:examples` task.** `pkl eval` every published example
  Taskfile so schema/example-pin drift is caught before it
  ships — would have flagged the `examples/*` 0.1.0 pin that
  silently rode through three releases.
- **Action input `cache-pkl: false` (opt-in).** When `true`,
  the composite action wraps `actions/cache@v4` around
  `~/.pkl/cache` keyed on `PklProject.deps.json` +
  `Taskfile.pkl`. Override the key via `pkl-cache-key`. Off by
  default — projects that don't import remote Pkl packages
  don't pay the cache restore/save cost.
- **"Used by" README section + library-author SKILL section.**
  Knowledge extracted from kawaz/pkf-tasks (DR-0001 …
  DR-0004): `abstract module` + `extends` for polymorphism,
  `(base) { cmd = ...; description = ... }` object-amends,
  `allTasks: Listing<Task>` export, `name = "<scope>:<action>"`
  namespace convention, runtime dispatch pattern (Pkl can't see
  CWD), `read("env:X")` pitfalls. Recipe 12 is a copy-paste
  skeleton for the layout.
- **Environment / args / params policy section in README.**
  The non-obvious rules in one place — layer order (host <
  defaults.Env < task.Env < params), the deliberate asymmetry
  that `cmd` sees host env but the action key never hashes it,
  when to use `read("env:X")` vs `inheritEnv = false`, and the
  bool-param value-less form. Aimed at AI agents that were
  guessing the wrong way around.

### Fixed

- **Examples were pinned to `pkfire@0.1.0` across three
  releases.** `bump-version.sh` and
  `check-version-consistency.sh` used `git ls-files
  'examples/<name>/**/*.pkl'`, but git pathspec `**` matches
  **one or more** directory segments — top-level
  `examples/<name>/Taskfile.pkl` was silently invisible. Fix:
  enumerate the four example Taskfiles directly. examples
  swept to the current version.
- **Action.yml version resolver.** Now normalizes
  `v0.5.0` / `0.5.0` / `v0` / `pkfire@0.5.0` to the same
  underlying release tag.

### Changed

- `actions/checkout@v4` → `@v5`, `actions/setup-go@v5` → `@v6`
  across all workflows. Silences the Node.js 20 deprecation
  notice ahead of the 2026-06-02 forced runtime bump.
- All Pkl files in `pkl/`, `examples/`, and `skills/` reformatted
  with `pkl format`. No semantic changes; long-line wraps and
  spaces around `|` in type unions.

## [0.4.0] - 2026-05-11

### Added

- **Default-on `inheritEnv`.** New `Task.inheritEnv: Boolean = true`.
  By default `cmd` now sees pkfire's full ambient environment
  (`os.Environ()`), matching `just`/`make`/`npm run` semantics — so
  `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, locale, and dev-tool sockets
  pass through without `env { ["SSH_AUTH_SOCK"] = read("env:...") }`
  boilerplate. Set `inheritEnv = false` for hermetic tasks; that
  mode preserves the pre-0.4 small allowlist (`PATH`, `HOME`,
  `LANG`, ...). In both modes only the schema-declared `env { ... }`
  contributes to the action key, never the host environment.
- **Variadic tail args via `acceptsArgs`.** New
  `Task.acceptsArgs: Boolean = false`. When true,
  `pkf run <task> -- a b c` forwards `a b c` to `cmd` as `$1`,
  `$2`, ... and `$@` (using `bash -c '<script>' pkf a b c`). Maps
  to just's `*ARGS` shape. The args fold into the action key when
  `cache = true`, so different invocations cache as different
  entries.
- **Typed named flags via `params { Param ... }`.** New
  `Task.params: Listing<Param>` with the `Param` class
  (`name`/`type: "string"|"enum"|"int"|"bool"`/`choices`/`default`/`description`).
  The caller passes `pkf run <task> --<name>=<value>`; pkf
  validates the value's *type* (enum membership, integer
  parsability, "true"/"false" for bool) *before* the cmd runs, then
  exposes each resolved value to `cmd` as `$NAME` (uppercased).
  Bool params take the value-less form `--flag` (= true) so they
  don't consume the next token; explicit false is `--flag=false`.
  Defaults are themselves type-checked, so a typo like
  `default = "abc"` on an int param fails fast. Missing required
  params (no `default`) error client-side. Resolved values fold
  into the action key when `cache = true`, so `--bump=patch` and
  `--bump=minor` cache separately. Recipe at
  `skills/pkfire/assets/recipes/11-named-params.pkl`.
- **Task names may now contain `/`.** The name regex is relaxed
  from `^[a-zA-Z][a-zA-Z0-9_:.-]*$` to
  `^[a-zA-Z][a-zA-Z0-9_:./-]*$`. Lets the directory tree drive task
  identity (`check-translate/docs:DESIGN`,
  `services/api/build`) when one task per subtree is the natural
  decomposition. Cache layout is unaffected — entries are keyed by
  the action-key digest, not the task name.

### Changed

- Schema bumped to 0.4.0. Adds `inheritEnv`, `acceptsArgs`,
  `params` to `Task`; adds the `Param` class. All new fields have
  sensible defaults so an existing 0.3.x Taskfile keeps evaluating
  unchanged; but the runtime behavior shifts for tasks that
  previously relied on the pre-0.4 hermetic-allowlist env: tasks
  that now see `SSH_AUTH_SOCK` (etc.) get them via inheritance.
  Set `inheritEnv = false` per-task to opt back into the old
  behavior.

### Added (services + supervision, all new in 0.4.0)

- **Per-service granular restart in `pkf up --watch`.** Each service
  now has its own action key tracked across watch iterations. On a
  file event, `pkf` recomputes every service's key and restarts only
  the ones whose key actually changed. Editing `src/api/foo.ts` no
  longer takes down `db` (which had a 15-second crash-recovery
  window), only `api`. The pre-service plan is re-executed each
  iteration so cached steps skip immediately.
- **Per-service log prefix.** Service stdout/stderr lines are now
  prefixed with `[<service-name>] ` so a `pkf up dev` mixing db +
  api + web in one terminal stays readable. Partial lines are
  buffered until the trailing newline arrives, and any unflushed
  remainder is emitted (with a synthesized newline) when the service
  exits, so nothing is dropped.
- **Reuse + readiness now apply to `pkf up`, not just
  `pkf run` + `services { ... }`.** A service's `readyPort`/`readyCmd`
  is consulted before `pkf up` spawns it; an already-running
  instance (typically another `pkf up` session in a different shell
  or a docker-compose stack) is reused, and shutdown leaves the
  reused process alone. `pkf up dev` in two terminals no longer
  port-collides.
- **Aggregator targets are first-class.** A non-service task that
  exists only to list services in `deps { ... }` (the canonical
  `local dev = new Task { deps { db; api; web } }` pattern) now
  works as a `pkf up dev` target — pkfire strips the service deps
  from the pre-service plan instead of erroring out.
- **Readiness probes (`readyPort`, `readyCmd`,
  `readyTimeoutSeconds`).** A service that declares a probe is
  *reused* when the probe already passes — pkfire dials once
  before spawning, and on success skips both the spawn and the
  teardown. `pkf run e2e` against an already-running `pkf up dev`
  no longer port-collides; it logs `reusing existing service "db"`
  and lets the dev session keep ownership. After a fresh spawn,
  pkfire polls the probe (every 250ms, up to
  `readyTimeoutSeconds`) before letting dependent services or the
  body task's cmd start, replacing hand-rolled `until pg_isready`
  loops in user `cmd`s. `readyPort` and `readyCmd` compose: both
  must pass when both are set.
- **Long-running services via `pkf up`.** A new `service: Boolean`
  field on `Task` marks a task as a supervised process. `pkf up
  <target>` runs every non-service dep first, then starts the
  services concurrently and blocks until Ctrl+C. `pkf up --watch
  <target>` adds a stop-rebuild-restart loop on input changes. The
  runner now sets every cmd as a process-group leader and signals
  the whole group on cancel (SIGTERM → grace → SIGKILL), so a
  `bash -c "node server.js"` style task no longer leaks its node
  child. Grace period is per-task via
  `shutdownTimeoutSeconds: Int = 5`. Recipe at
  `skills/pkfire/assets/recipes/08-services.pkl` shows a full
  db + api + web stack.
- **Tests against live services via `services { ... }` on a task.**
  A task can declare `services: Listing<Task>`; `pkf run` brings
  those services up before invoking `cmd` and releases them when
  it returns (success or failure). Services nest — listing `api`
  also brings up `api.services` (typically `db`). Cache hits skip
  spinup entirely. Recipe 09 covers the e2e + ephemeral postgres
  case.
- GitHub Action at the repo root (`mizchi/pkfire@pkfire@<version>`)
  that installs `pkf` and the Pkl CLI on the runner.
- Pre-built `pkf` binaries for `linux/darwin × amd64/arm64`,
  attached to each release.
- `Test` CI workflow that runs the `examples/dogfood` `ci` aggregate
  (vet + go-test + pkl-test + cross-compile matrix + checksum +
  integration smoke) on every PR and push to main; the Release
  workflow gates on it.
- `scripts/check-version-consistency.sh` (and `bump-version.sh`) to
  keep every `pkfire@<ver>` reference in sync with the version
  declared in `pkl/PklProject`. Wired into CI.
- `pkf init` now embeds the running binary's version into the
  `amends` URI (release builds pin to their package; dev builds fall
  back to the main HTTPS URL).

### Changed

- Schema bumped to 0.3.0. Adds `service`,
  `shutdownTimeoutSeconds`, `services`, `readyPort`, `readyCmd`,
  `readyTimeoutSeconds` to `Task`; all are optional with sensible
  defaults, so existing 0.1.0 Taskfiles keep evaluating, but an
  older binary cannot decode a 0.3.0 schema. Bump `pkf` and the
  `amends` URI together.

## [0.1.0] - 2026-05-10

### Added

- First Pkl package release at
  `package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.1.0`.
- Typed DAG schema with `Task` references for `deps`, action key
  hashing over inputs/cmd/env/tools, local CAS, watch mode, and an
  HTTP remote-cache backend (with a Cloudflare Worker reference
  implementation).
- Examples for basic, Node, Rust, monorepo, dogfood, and the
  remote-cache worker.
- Skill at `skills/pkfire/SKILL.md` plus seven copy-paste recipes.
- Nix flake (`nix run github:mizchi/pkfire`) and Go install path.

[Unreleased]: https://github.com/mizchi/pkfire/compare/pkfire@0.15.0...HEAD
[0.15.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.15.0
[0.14.2]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.14.2
[0.14.1]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.14.1
[0.13.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.13.0
[0.12.4]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.12.4
[0.12.3]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.12.3
[0.12.2]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.12.2
[0.12.1]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.12.1
[0.12.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.12.0
[0.11.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.11.0
[0.10.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.10.0
[0.9.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.9.0
[0.8.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.8.0
[0.7.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.7.0
[0.6.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.6.0
[0.5.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.5.0
[0.4.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.4.0
[0.3.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.3.0
[0.2.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.2.0
[0.1.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.1.0
