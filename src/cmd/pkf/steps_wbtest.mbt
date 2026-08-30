// Tests for multi-step lowering.
//
// The expansion is where a mistake is quiet: a chain that loses its
// order still builds *something*, an umbrella credited as a producer
// still draws a graph, and a consumer whose key stops seeing what a
// pipeline wrote still returns a plausible cache hit. The end-to-end
// behaviour — step 1 staying cached while step 2 re-runs — is the
// `steps-partial-rebuild` conformance scenario.

///|
fn step_of(
  name : String,
  cmd : String,
  inputs : Array[String],
  outputs : Array[String],
) -> Step {
  Step::{ name, cmd, inputs, outputs, description: None }
}

///|
fn stepped_task(name : String, deps : Array[String], steps : Array[Step]) -> Task {
  { ..graph_test_task(name, [], [], deps, None), cmd: "", steps }
}

///|
fn names_of(tasks : Array[Task]) -> Array[String] {
  let out : Array[String] = []
  for task in tasks {
    out.push(task.name)
  }
  out
}

///|
test "a pipeline lowers to one task per step plus its umbrella" {
  let task = stepped_task("bundle", [], [
    step_of("codegen", "gen", ["schema/**"], ["gen/**"]),
    step_of("compile", "cc", ["gen/**"], ["lib/**"]),
  ])
  let lowered = lower_steps(task)
  assert_eq(names_of(lowered), ["bundle/codegen", "bundle/compile", "bundle"])
  // Each step carries only its own reads and writes, so each gets its
  // own key — which is the entire point of the feature.
  assert_eq(lowered[0].inputs, ["schema/**"])
  assert_eq(lowered[0].outputs, ["gen/**"])
  assert_eq(lowered[1].inputs, ["gen/**"])
  assert_eq(lowered[1].cmd, "cc")
}

///|
test "steps run in declaration order, not in whatever order infers" {
  // A step with no outputs — a migration, a check — would float free
  // of the pipeline if ordering came from artifacts alone. The author
  // wrote the sequence down; that is the sequence.
  let task = stepped_task("pipe", ["setup"], [
    step_of("first", "a", [], []),
    step_of("second", "b", [], []),
    step_of("third", "c", [], []),
  ])
  let lowered = lower_steps(task)
  // The first step inherits the task's own dependencies, so depending
  // on the task makes the whole pipeline wait for what it waits for.
  assert_eq(lowered[0].deps, ["setup"])
  assert_eq(lowered[1].deps, ["pipe/first"])
  assert_eq(lowered[2].deps, ["pipe/second"])
  // Depending on the last step pulls in all of them through the chain.
  assert_eq(lowered[3].deps, ["pipe/third"])
  assert_eq(lowered[3].cmd, "")
}

///|
test "the umbrella carries the union of the steps' inputs and outputs" {
  // Not to make it a producer — it spawns nothing — but so
  // `pkf clean bundle` and `pkf affected` see the pipeline as the one
  // thing its author wrote.
  let task = stepped_task("bundle", [], [
    step_of("a", "x", ["src/**"], ["gen/**"]),
    step_of("b", "y", ["gen/**"], ["dist/**"]),
  ])
  let umbrella = lower_steps(task)[2]
  assert_eq(umbrella.inputs, ["src/**", "gen/**"])
  assert_eq(umbrella.outputs, ["gen/**", "dist/**"])
  // The umbrella keeps its `steps`, which is how `pkf describe` can
  // still show the pipeline and how a `provides.executable` on it is
  // recognised as speaking for something that gets produced.
  assert_eq(umbrella.steps.length(), 2)
}

///|
test "a step is internal, so `pkf list` still shows one task" {
  let task = stepped_task("bundle", [], [step_of("only", "x", [], [])])
  let lowered = lower_steps(task)
  assert_eq(lowered[0].visibility, "internal")
  // The umbrella keeps whatever the author declared.
  assert_eq(lowered[1].visibility, "public")
}

///|
test "steps inherit the task's configuration, not just its name" {
  // A pipeline is configured once. A step says what it runs and what
  // it touches; everything else is the task's.
  let task = {
    ..stepped_task("bundle", [], [step_of("a", "x", ["src/**"], [])]),
    env: Map([("NODE_ENV", "production")]),
    workdir: Some("packages/web"),
    hermetic: true,
    inherit_env: false,
  }
  let step = lower_steps(task)[0]
  assert_eq(step.env.get("NODE_ENV"), Some("production"))
  assert_eq(step.workdir, Some("packages/web"))
  assert_true(step.hermetic)
  assert_false(step.inherit_env)
}

///|
test "providers stay on the umbrella, which is what dependents name" {
  let task = {
    ..stepped_task("cli", [], [step_of("link", "ld", [], ["dist/cli"])]),
    provides: Providers::{ executable: "dist/cli", env: Map([]) },
  }
  let lowered = lower_steps(task)
  assert_true(lowered[0].provides.is_empty())
  assert_eq(lowered[1].provides.executable, "dist/cli")
  // And it validates against the union of what the steps write, since
  // the umbrella's own `outputs` is that union.
  assert_true(provider_declaration_error(lowered[1]) is None)
}

///|
test "the ways a pipeline can be malformed are all refused" {
  let one = step_of("a", "x", [], [])
  // A task is either one command or a sequence of them.
  assert_true(
    step_declaration_error({
      ..stepped_task("t", [], [one]),
      cmd: "echo hi",
    })
    is Some(_),
  )
  // Two steps answering to one name would collide as `t/a`.
  assert_true(
    step_declaration_error(
      stepped_task("t", [], [one, step_of("a", "y", [], [])]),
    )
    is Some(_),
  )
  // A service's lifetime spans one command; which step of a pipeline
  // it should wrap has no answer worth guessing at.
  assert_true(
    step_declaration_error({
      ..stepped_task("t", [], [one]),
      services: ["api"],
    })
    is Some(_),
  )
  assert_true(
    step_declaration_error({ ..stepped_task("t", [], [one]), service: true })
    is Some(_),
  )
  assert_true(step_declaration_error(stepped_task("t", [], [one])) is None)
  // A task with no steps is not a pipeline and is never rejected here.
  assert_true(
    step_declaration_error(graph_test_task("plain", [], [], [], None)) is None,
  )
}

///|
test "expansion replaces the task in place and keeps the reading order" {
  let plan = graph_test_plan([
    graph_test_task("before", [], [], [], None),
    stepped_task("bundle", [], [
      step_of("a", "x", [], ["gen/**"]),
      step_of("b", "y", ["gen/**"], []),
    ]),
    graph_test_task("after", [], [], [], None),
  ])
  assert_true(expand_step_tasks(plan.tasks, plan.task_order) is None)
  assert_eq(plan.task_order, [
    "before", "bundle/a", "bundle/b", "bundle", "after",
  ])
  // The authored name still resolves — to the umbrella.
  assert_eq(plan.tasks.get("bundle").unwrap().cmd, "")
  assert_eq(plan.tasks.get("bundle/a").unwrap().cmd, "x")
}

///|
test "a step whose name is already taken is a collision, not a silent overwrite" {
  // Two tasks answering to one name means `pkf run` picks whichever
  // the map happened to keep.
  let plan = graph_test_plan([
    graph_test_task("t/a", [], [], [], None),
    stepped_task("t", [], [step_of("a", "x", [], [])]),
  ])
  assert_eq(expand_step_tasks(plan.tasks, plan.task_order), Some("t/a"))
}

///|
test "an umbrella is neither a producer nor a consumer" {
  // It spawns no process, so it writes nothing and reads nothing.
  // Crediting it with its steps' union would draw an edge from every
  // step into the task those steps make up.
  let plan = graph_test_plan([
    stepped_task("bundle", [], [
      step_of("gen", "x", ["src/**"], ["dist/**"]),
      step_of("check", "y", ["dist/**"], []),
    ]),
  ])
  assert_true(expand_step_tasks(plan.tasks, plan.task_order) is None)
  let graph = build_action_graph(plan, ".", ["bundle"])
  assert_eq(graph.nodes.get("bundle").unwrap().outputs, [])
  assert_eq(graph.nodes.get("bundle").unwrap().inputs.length(), 0)
  // The step-to-step edge is still there, from the declared chain.
  assert_eq(inferred_edges_of(graph, "bundle").length(), 0)
}

///|
test "a consumer's key sees what a pipeline wrote, through the umbrella" {
  // `deps { pipeline }` names the umbrella, which produces nothing.
  // Stopping there would leave the consumer blind to the bytes it
  // consumes — the exact unsoundness declaring the dependency closes.
  let plan = graph_test_plan([
    stepped_task("pipeline", [], [step_of("gen", "x", ["src/**"], ["dist/**"])]),
    graph_test_task("consumer", ["own/**"], [], ["pipeline"], None),
  ])
  assert_true(expand_step_tasks(plan.tasks, plan.task_order) is None)
  let graph = build_action_graph(plan, ".", ["consumer"])
  // The producer reached through the umbrella is the step, and its
  // output pattern is what the consumer's key will hash.
  assert_eq(graph.nodes.get("pipeline/gen").unwrap().outputs, ["dist/**"])
  assert_eq(graph.nodes.get("pipeline").unwrap().outputs, [])
}
