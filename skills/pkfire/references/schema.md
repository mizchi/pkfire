# Taskfile schema contract

This reference describes the `pkfire@0.14.0` Pkl contract. The
normative source in the repository is `pkl/Taskfile.pkl`.

## Module shape

A consumer module amends the schema and populates two listings:

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.14.0#/Taskfile.pkl"

defaults {
  env {
    ["CI"] = "true"
  }
}

local build: Task = new {
  name = "build"
  cmd = "moon build"
}

tasks { build }

workflowTests {
  new {
    name = "MoonBit source affects build"
    changed { "src/main.mbt" }
    direct { "build" }
    tasks { "build" }
  }
}
```

Every authored task must appear in `tasks`. Duplicate task names fail
during Pkl rendering.

## Defaults

| Field | Type | Default | Current runtime behavior |
| --- | --- | --- | --- |
| `shell` | `String` | `"bash"` | Emitted in the plan, but Task values render their own fixed default; do not rely on it to override every task. |
| `shellFlags` | `List<String>` | `List("-c")` | Same limitation as `shell`. |
| `env` | `Mapping<String, String>` | empty | Merged before each task's own `env`; not included in the action key. |

Set per-task `shell` and `shellFlags` when they differ from
`bash -c`.

## Task

| Field | Type | Default | Contract |
| --- | --- | --- | --- |
| `name` | constrained `String` | required | Must match `^[a-zA-Z][a-zA-Z0-9_:./-]*$`. |
| `cmd` | `String?` | `null` | Non-empty command; null renders as empty and creates a deps-only umbrella. |
| `shell` | `String` | `"bash"` | Executable used for the command. |
| `shellFlags` | `List<String>` | `List("-c")` | Arguments placed before `cmd`. |
| `inputs` | `Listing<String>` | empty | Globs used for hashing, affected analysis, and watch. |
| `outputs` | `Listing<String>` | empty | Paths or globs captured after success and restored on a hit. |
| `deps` | `Listing<Task>` | empty | Direct Task references that must finish first. |
| `env` | `Mapping<String, String>` | empty | Task environment overlay; included in the action key. |
| `tools` | `Mapping<String, String>` | empty | Declared tool versions; included in the action key but not installed by pkf. |
| `cache` | `Boolean` | `true` | Disable to always run and never restore/store. |
| `workdir` | `String?` | `null` | Command working directory. See runtime reference for current path caveats. |
| `description` | `String?` | `null` | Human-facing text. |
| `visibility` | enum: `"public"`, `"internal"` | `"public"` | Internal tasks remain runnable but are hidden unless `--all` is used. |
| `quiet` | `Boolean` | `false` | Schema field retained in the rendered plan; current runner does not consistently use it. |
| `service` | `Boolean` | `false` | Marks a long-running process for `up` or `services`. |
| `shutdownTimeoutSeconds` | non-negative `Int` | `5` | Grace between SIGTERM and SIGKILL. |
| `services` | `Listing<Task>` | empty | Service tasks kept alive around this task's command. |
| `readyPort` | `Int` in 0...65535 | `0` | TCP readiness and reuse probe; zero disables it. |
| `readyCmd` | `String` | `""` | Exit-zero readiness probe; empty disables it. |
| `readyTimeoutSeconds` | non-negative `Int` | `30` | Post-spawn readiness budget. |
| `inheritEnv` | `Boolean` | `true` | Whether the process inherits ambient environment variables. |
| `acceptsArgs` | `Boolean` | `false` | Allows positional args after `--`. |
| `params` | `Listing<Param>` | empty | Typed named target flags. |
| `specRef` | `String?` | `null` | Optional pkspec Scenario id; schema-rendered but currently discarded by the MoonBit plan parser. |

Use `Listing` syntax for `inputs`, `outputs`, `deps`, `services`,
and `params`. `shellFlags` is a `List`, not a `Listing`.

## Param

| Field | Type | Default | Contract |
| --- | --- | --- | --- |
| `name` | constrained `String` | required | Must match `^[a-z][a-zA-Z0-9_]*$`; runtime exports the uppercase form. |
| `type` | enum: `string`, `enum`, `int`, `bool` | `"string"` | Validation mode. |
| `choices` | `Listing<String>` | empty | Allowed enum values. |
| `default` | `String?` | `null` | Null means required; int and bool defaults are still written as strings. |
| `description` | `String?` | `null` | Human-facing help. |

Example:

```pkl
params {
  new {
    name = "profile"
    type = "enum"
    choices { "debug"; "release" }
    default = "debug"
  }
  new {
    name = "jobs"
    type = "int"
    default = "4"
  }
  new {
    name = "watch"
    type = "bool"
    default = "false"
  }
}
```

At runtime these values are `$PROFILE`, `$JOBS`, and `$WATCH`.

## WorkflowTest

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `name` | non-empty `String` | required | Case label. |
| `changed` | `Listing<String>` | required | Repo-relative paths to simulate. |
| `tasks` | `Listing<String>` | required | Expected final topological plan. |
| `direct` | `Listing<String>` | empty | Optional expected direct input matches. |

Run all cases with `pkf affected --check`. This is the preferred
contract test when editing `inputs` or `deps`.

## Rendered envelope

Pkl emits `output.value` with:

```text
Rendered {
  defaults: Defaults
  taskOrder: Listing<String>
  tasks: Mapping<String, RenderedTask>
  workflowTests: Listing<RenderedWorkflowTest>
}
```

`tasks` is keyed by unique task name. `deps` and `services` are
projected from typed Task references to name listings. The MoonBit
runner renders this value to JSON in-process, then parses the plan.

## Composition

For a single entry point split across files, export typed values:

```pkl
// tasks/build.pkl
import "../Taskfile.pkl"

build: Taskfile.Task = new {
  name = "build"
  cmd = "moon build"
}

allTasks: Listing<Taskfile.Task> = new { build }
```

Then import and spread from the root module:

```pkl
import "tasks/build.pkl" as buildTasks

tasks { ...buildTasks.allTasks }
```

For reusable libraries, declare pkfire as a `PklProject` dependency,
import `@pkfire/Taskfile.pkl`, and export
`allTasks: Listing<Taskfile.Task>`. Use `extends` for implementations
of an `abstract module`; do not `amends` an abstract module.
