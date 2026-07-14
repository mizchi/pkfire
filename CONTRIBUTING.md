# Contributing to pkfire

Thanks for considering a contribution. The bar is low — patches,
recipes, examples, and bug reports are all welcome.

## Local setup

```sh
moon build src/cmd/pkf --target native --release  # build pkf
BIN=_build/native/release/build/mizchi/pkf/src/cmd/pkf/pkf.exe
pkl test --project-dir pkl                      # schema-level tests
"$BIN" run -f examples/dogfood/Taskfile.pkl ci  # the full dogfood gate
```

The `dogfood ci` aggregate is what CI runs on every PR (`moon check`,
`moon test`, `pkl test`, the binary build, the integration smoke, and
`init-smoke`). If it passes locally it will pass in CI. The contract
harness (`"$BIN" run conformance`) checks the binary against the frozen
goldens — run it after any behavior-affecting change.

## What goes where

- **Pkl schema** lives in `pkl/Taskfile.pkl`. Schema-level tests live
  in `pkl/Taskfile.test.pkl` (`pkl test`).
- **`pkf` runner** is a MoonBit program under `src/`
  (`cmd/pkf` CLI entry + `loader` for the embedded Pkl evaluator).
  Contract tests live in `conformance/` (MoonBit runner + frozen
  `golden/`).
- **User-facing examples** are under `examples/`. `examples/dogfood/`
  deliberately uses a relative `amends` so it tests the in-tree
  schema; everything else uses the published package URI.
- **Skill + recipes** are under `skills/pkfire/`. Recipes are
  copy-paste templates — each one stands alone and uses the published
  package URI.

## Cutting a release

```sh
scripts/bump-version.sh <new-version>
git commit -am "release: pkfire@<new-version>"
git tag    "pkfire@<new-version>"
git push origin main "pkfire@<new-version>"
```

The Release workflow runs `dogfood ci`, then publishes the Pkl
package and the `pkf` binaries to a single GitHub release tagged
`pkfire@<new-version>`. After that the Action becomes resolvable as
`mizchi/pkfire@pkfire@<new-version>`.

## Style notes

- Tasks always use direct `Task` references in `deps`, never strings.
- `inputs` should describe the smallest set that, if changed, ought to
  invalidate the cache. Over-broad inputs cost rebuilds; under-broad
  inputs cause stale hits.
- Prefer adding a recipe under `skills/pkfire/assets/recipes/` over
  expanding a single example, when a pattern is generally useful.
- Public-facing docs (README, SKILL.md) are written in English.
