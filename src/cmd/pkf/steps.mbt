// Lowering a multi-step task into several actions.
//
// Until now one Task became exactly one action, which is why pkfire
// cached at the granularity of whole commands: a `build` that
// generated code, compiled it and linked it was one key, so touching
// anything re-ran all three. `steps` splits that. Each step declares
// its own `inputs` and `outputs` and gets its own action key and its
// own cache entry, so an edit that only reaches the last step reuses
// the first two.
//
// The lowering is an expansion rather than a new node kind: a task
// with `steps` becomes N ordinary tasks named `<task>/<step>`, chained
// by `deps`, plus the original task turned into a deps-only umbrella
// over them. Everything downstream — the action graph, the scheduler,
// the cache, the sandbox, providers, `explain`, `graph`, `lint` —
// already knows what a task is and needs no second concept. This is
// the same trick Bazel's macro layer plays: expand into the primitive
// the engine already runs, rather than teach the engine a new shape.
//
// What a step deliberately does *not* carry is configuration. `shell`,
// `env`, `workdir`, `tools`, `cache`, `hermetic`, `inheritEnv` and
// `params` all come from the task, so a pipeline is configured once
// and a step says only what it runs and what it touches.

///|
/// One command inside a task.
struct Step {
  name : String
  cmd : String
  inputs : Array[String]
  outputs : Array[String]
  description : String?
}

///|
/// The name a step runs under.
///
/// `<task>/<step>` rather than something unspellable, because it is
/// what every message the user sees will call it — a cache-hit line, a
/// `--keep-going` skip, a node in `pkf graph` — and because
/// `pkf run bundle/link` should then work for exactly the reason it
/// looks like it should.
fn step_task_name(task : String, step : String) -> String {
  task + "/" + step
}

///|
/// Why a task's `steps` cannot be lowered, if it cannot.
///
/// Checked before expansion so the message names the authored task
/// rather than a synthetic one the user never wrote.
fn step_declaration_error(task : Task) -> String? {
  if task.steps.length() == 0 {
    return None
  }
  if task.cmd.length() > 0 {
    return Some(
      "task `\{task.name}` declares both `cmd` and `steps`; a task is either one command or a pipeline of them",
    )
  }
  if task.service {
    return Some("task `\{task.name}` cannot be both a service and a pipeline of steps")
  }
  // Services wrap a single command's lifetime. Around which step of a
  // pipeline they should be up is a real question with no obvious
  // answer, and starting them once per step would be neither of the
  // things anyone means. Refuse rather than pick.
  if task.services.length() > 0 {
    return Some(
      "task `\{task.name}` declares both `services` and `steps`; a service's lifetime spans one command, so put the steps in separate tasks and declare the services on the one that needs them",
    )
  }
  let seen : Map[String, Bool] = Map([], capacity=task.steps.length())
  for step in task.steps {
    if seen.contains(step.name) {
      return Some(
        "task `\{task.name}` declares two steps named `\{step.name}`; step names must be unique within a task",
      )
    }
    seen[step.name] = true
  }
  None
}

///|
/// Every output any of `task`'s steps declares, in order and without
/// duplicates.
///
/// The umbrella carries this so `pkf clean <task>` and `pkf affected`
/// see the pipeline as one thing, which is how its author thinks of
/// it. It does not make the umbrella a *producer*: it spawns no
/// process, and `build_action_graph` credits outputs only to tasks
/// that run something.
fn step_union(patterns : Array[Array[String]]) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = Map([], capacity=8)
  for group in patterns {
    for pattern in group {
      if !seen.contains(pattern) {
        seen[pattern] = true
        out.push(pattern)
      }
    }
  }
  out
}

///|
/// The tasks one authored task lowers to: one per step, then the
/// umbrella that replaces the original.
///
/// Steps are chained through `deps` rather than left to artifact
/// inference. Inference would order any pair where one reads what the
/// other writes, but a step that only has a side effect — a migration,
/// a `rm -rf`, a check that writes nothing — declares no outputs and
/// would float free of the pipeline it was written into. Declaration
/// order is what the author wrote down, so it is what the runner
/// honours.
fn lower_steps(task : Task) -> Array[Task] {
  let out : Array[Task] = []
  let mut previous : String? = None
  for step in task.steps {
    let name = step_task_name(task.name, step.name)
    // The first step inherits the task's dependencies; the rest depend
    // on the step before them. So depending on the task means the
    // whole pipeline waits for what the task waits for.
    let deps = match previous {
      Some(prior) => [prior]
      None => task.deps
    }
    out.push({
      ..task,
      name,
      cmd: step.cmd,
      inputs: step.inputs,
      outputs: step.outputs,
      deps,
      steps: [],
      // A step is a piece of a task, not a task someone runs by
      // name from memory. `pkf list --all` and `pkf graph --all`
      // still show them, and `pkf run <task>/<step>` still works.
      visibility: "internal",
      description: step.description,
      // The umbrella keeps the providers: they describe what the
      // pipeline as a whole hands over, and a dependent names the
      // task, not its last step.
      provides: Providers::empty(),
    })
    previous = Some(name)
  }
  // The umbrella. Depending on the last step is enough to pull in all
  // of them, because the chain above already orders the rest.
  let step_inputs : Array[Array[String]] = []
  let step_outputs : Array[Array[String]] = []
  for step in task.steps {
    step_inputs.push(step.inputs)
    step_outputs.push(step.outputs)
  }
  out.push({
    ..task,
    cmd: "",
    deps: match previous {
      Some(last) => [last]
      None => task.deps
    },
    inputs: step_union(step_inputs),
    outputs: step_union(step_outputs),
  })
  out
}

///|
/// Rewrite a plan so every multi-step task is replaced by its steps
/// plus its umbrella.
///
/// Order matters for readability rather than correctness: the steps
/// are inserted where the task was declared, so `pkf list --all` and
/// `pkf graph` read top to bottom the way the Taskfile does.
///
/// Returns the name of the first synthetic task that would collide
/// with an authored one, which is fatal: two tasks answering to one
/// name means `pkf run` would silently pick whichever the map kept.
fn expand_step_tasks(
  tasks : Map[String, Task],
  task_order : Array[String],
) -> String? {
  // Name -> the step tasks it lowers to, in pipeline order. Built
  // first so the collision check can run before anything is written.
  let lowered : Map[String, Array[Task]] = Map([], capacity=4)
  for name in task_order {
    let task = match tasks.get(name) {
      Some(t) => t
      None => continue
    }
    if task.steps.length() == 0 {
      continue
    }
    let group : Array[Task] = []
    for produced in lower_steps(task) {
      if produced.name == name {
        // The umbrella replaces the authored task in place.
        tasks[name] = produced
      } else {
        if tasks.get(produced.name) is Some(_) {
          return Some(produced.name)
        }
        group.push(produced)
      }
    }
    lowered[name] = group
  }
  if lowered.length() == 0 {
    return None
  }
  for _, group in lowered {
    for step_task in group {
      tasks[step_task.name] = step_task
    }
  }
  // Steps land immediately before the task they came from, so
  // `pkf list --all` and `pkf graph` read in the order the Taskfile
  // does — and in the order they will run.
  let reordered : Array[String] = []
  for name in task_order {
    match lowered.get(name) {
      Some(group) =>
        for step_task in group {
          reordered.push(step_task.name)
        }
      None => ()
    }
    reordered.push(name)
  }
  task_order.clear()
  for name in reordered {
    task_order.push(name)
  }
  None
}
