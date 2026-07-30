# pkf CLI contract

This is the implemented `pkf 0.14.0` command surface. Prefer the
dispatcher in `src/cmd/pkf/main.mbt` over generated completions or
older README examples.

For commands that locate a Taskfile, put `-f/--file` before the first
positional argument:

```sh
pkf run -f path/Taskfile.pkl build
pkf hooks -f path/Taskfile.pkl install
```

## Inspection

| Command | Implemented arguments | Result |
| --- | --- | --- |
| `version` | none | Print the pkf version. `--version` and top-level `-v` are aliases. |
| `list` | `-v/--verbose`, `--all`, `--json` | List visible tasks; verbose adds params/deps/inputs/outputs. |
| `graph` | `--all`, `--json` | Print dependency trees or JSON tasks and edges. |
| `info` | `--all`, `--json` | Summarize Taskfile path, schema URI/version, defaults, tasks, and workflow tests. |
| `describe` | `[--json] <task>` | Show one rendered task. Put `--json` before the task. |
| `explain` | `<task>` | Show the configured action-key surface. It intentionally omits file hashing and CLI params, so its printed key is not necessarily a real run key. |
| `doctor` | `--json` | Check pkf path, external Pkl CLI, cache, remote config, and Taskfile discovery. |
| `lint` | `--json` | Always prints `{"findings":[...]}`; exits non-zero for error findings. |

`list --long`, `list --unsorted`, list color selection, graph
formats, and graph target selection are not implemented.

## Execution

| Command | Implemented arguments | Result |
| --- | --- | --- |
| `run` | `<task> [--declared=value]... [-- positional...]` | Run exactly one target and its transitive deps. |
| `affected` | `<path>...`, `--changed=<file>`, or `--check` | Print the affected plan or run authored workflow tests. |
| `watch` | `[task...]` | Watch the Taskfile directory and run affected non-service tasks, optionally filtered to exact names. |
| `up` | `[service...]` | Start all or selected service tasks in the foreground. |
| `clean` | `[task-or-glob...]` | Recursively remove declared outputs; no args means all tasks with outputs. |

`run` does not currently implement a default target, multiple target
roots, parallelism, dry-run, hash printing, cache bypass/refresh,
timings, profiles, failure hooks, or remote-only lookup. Tokens that
look like `--dry-run` or `--no-cache` are parsed as named task values
and ignored when undeclared.

`affected` does not read Git history. It has no `--since`,
`--files`, `--explain`, target filter/execution, or dry-run flag.
Generate changed paths with Git separately:

```sh
git diff --name-only origin/main...HEAD > /tmp/changed.txt
pkf affected --changed=/tmp/changed.txt
```

`clean --dry-run` is a compatibility no-op: it still deletes outputs.
Never use it as a safety preview.

## Taskfile maintenance

| Command | Implemented arguments | Result |
| --- | --- | --- |
| `init` | `-f/--file FILE`, `--force` | Write a starter Taskfile. |
| `format` | `[--check] [path...]` | Run external `pkl format -w`, or `--diff-name-only` for check mode. |
| `migrate` | `--to=<version>`, `--dry-run`, `--skip-verify` | Rewrite the pinned `pkfire@<version>`; verify with external `pkl eval` unless skipped. |
| `hooks` | `install|uninstall|list`, install also accepts `--force` | Manage marked Git hook shims. |
| `pkl-cache` | `[warm] [path...]` | Run external `pkl eval` to warm `~/.pkl/cache`. |
| `completion` | `bash|zsh|fish` | Print a completion script. |

The generated completion scripts still advertise some Go-era flags
that the MoonBit dispatcher does not implement. Treat completion as a
typing aid, not an interface specification.

`lint --fix` and `lint --dry-run` are accepted but do not modify or
preview anything. `explain --diff` is also accepted and ignored.

## Cache maintenance

| Command | Arguments | Result |
| --- | --- | --- |
| `cache stats` | none | Print root, entry count, size, and oldest/newest timestamps. |
| `cache prune` | `--older-than DUR`, `--dry-run` | Remove old entries; duration accepts `d`, `h`, `m`, or `s`. |
| `cache rm` | one or more full keys or unique prefixes | Remove matching entries. |
| `cache clear` | `--yes` | Remove the entire CAS; refuses without confirmation. |

## Recommended inspection sequence

```sh
pkf version
pkf doctor
pkf info --json
pkf list -v
pkf graph --json
pkf lint
pkf affected --check
```

Use JSON modes when an agent needs stable structured data. Use
`pkl eval Taskfile.pkl` when validating the Pkl contract itself.
