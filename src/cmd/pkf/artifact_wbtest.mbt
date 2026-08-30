// Tests for the analysis phase: artifact provenance, derived edges,
// scheduling order, and the cycles derived edges can create.
//
// These build `Plan`s in memory rather than on disk. Everything under
// test is lexical — pattern intersection, edge derivation, topological
// order — so a fixture tree would only add I/O to the failure modes.
// The one function that does touch the filesystem,
// `consumed_artifact_hashes`, is covered through the action key in
// `cache_wbtest.mbt`.

///|
fn graph_test_task(
  name : String,
  inputs : Array[String],
  outputs : Array[String],
  deps : Array[String],
  workdir : String?,
) -> Task {
  Task::{
    name,
    cmd: "build",
    shell: "bash",
    shell_flags: ["-c"],
    inputs,
    outputs,
    deps,
    env: Map([], capacity=0),
    tools: Map([], capacity=0),
    cache: true,
    workdir,
    inherit_env: true,
    hermetic: false,
    steps: [],
    provides: Providers::empty(),
    params: [],
    accepts_args: false,
    service: false,
    quiet: false,
    services: [],
    ready_port: 0,
    ready_cmd: "",
    ready_timeout_seconds: 30,
    shutdown_timeout_seconds: 5,
    description: None,
    visibility: "public",
  }
}

///|
fn graph_test_plan(tasks : Array[Task]) -> Plan {
  let task_map : Map[String, Task] = Map([], capacity=tasks.length())
  let order : Array[String] = []
  for task in tasks {
    task_map[task.name] = task
    order.push(task.name)
  }
  Plan::{
    default_env: Map([], capacity=0),
    default_shell: "bash",
    default_shell_flags: ["-c"],
    tasks: task_map,
    task_order: order,
    workflow_tests: [],
  }
}

///|
/// Index of `name` in `order`, or -1. Used to assert relative order
/// without depending on what else the graph scheduled.
fn order_index(order : Array[String], name : String) -> Int {
  for i, n in order {
    if n == name {
      return i
    }
  }
  -1
}

///|
test "a task that reads another task's output runs after it" {
  // No `deps` anywhere: the only thing linking these two is that one
  // declares as output what the other declares as input. Listing the
  // consumer first is what makes the assertion meaningful — the
  // declared order says `consume` then `gen`.
  let gen = graph_test_task("gen", ["src/in.txt"], ["dist/out.txt"], [], None)
  let consume = graph_test_task(
    "consume", ["dist/out.txt"], ["report.txt"], [], None,
  )
  let plan = graph_test_plan([consume, gen])
  let graph = build_action_graph(plan, ".", ["consume", "gen"])
  assert_eq(graph.cycle, None)
  assert_true(
    order_index(graph.order, "gen") < order_index(graph.order, "consume"),
  )
}

///|
test "a consumed input is a generated artifact, an unproduced one is a source" {
  let gen = graph_test_task("gen", ["src/in.txt"], ["dist/out.txt"], [], None)
  let consume = graph_test_task(
    "consume", ["dist/out.txt", "conf/app.toml"], [], [], None,
  )
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume", "gen"])
  assert_eq(producers_of_input(graph, "consume", "dist/out.txt"), ["gen"])
  assert_eq(producers_of_input(graph, "consume", "conf/app.toml"), [])
  let node = graph.nodes.get("consume").unwrap()
  assert_true(node.inputs.contains(GeneratedArtifact("dist/out.txt", "gen")))
  assert_true(node.inputs.contains(SourceArtifact("conf/app.toml")))
}

///|
test "a directory output covers the files under it" {
  // `outputs { "dist" }` does not say whether dist is a file or a
  // directory. Treating it as only a file would miss every consumer
  // that reads a path inside it, which is the common case.
  let gen = graph_test_task("gen", ["src/**"], ["dist"], [], None)
  let consume = graph_test_task("consume", ["dist/app.js"], [], [], None)
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume", "gen"])
  assert_eq(producers_of_input(graph, "consume", "dist/app.js"), ["gen"])
}

///|
test "one input pattern can have several producers" {
  // `bundle` reads all of `dist/**`, which two tasks write into.
  // Stopping at the first producer would order it after one of them
  // and hash only that one's outputs into its key — the other could
  // change with `bundle` still hit.
  let js = graph_test_task("js", ["src/**"], ["dist/js/**"], [], None)
  let css = graph_test_task("css", ["styles/**"], ["dist/css/**"], [], None)
  let bundle = graph_test_task("bundle", ["dist/**"], [], [], None)
  let plan = graph_test_plan([bundle, js, css])
  let graph = build_action_graph(plan, ".", ["bundle", "js", "css"])
  let producers = producers_of_input(graph, "bundle", "dist/**")
  producers.sort_by(fn(a, b) { lex_cmp(a, b) })
  assert_eq(producers, ["css", "js"])
  assert_eq(inferred_edges_of(graph, "bundle").length(), 2)
  assert_true(
    order_index(graph.order, "js") < order_index(graph.order, "bundle"),
  )
  assert_true(
    order_index(graph.order, "css") < order_index(graph.order, "bundle"),
  )
}

///|
test "output patterns gain a subtree form unless they already have one" {
  let literal = graph_test_task("t", [], ["dist"], [], None)
  assert_eq(task_artifact_output_patterns(".", literal), ["dist", "dist/**"])
  // A pattern that already ends in `**` covers its own subtree; adding
  // `dist/**/**` would only cost matching time.
  let recursive = graph_test_task("t", [], ["dist/**"], [], None)
  assert_eq(task_artifact_output_patterns(".", recursive), ["dist/**"])
}

///|
test "a task does not consume its own outputs" {
  // A formatter reads and rewrites the same tree. That is a fixpoint,
  // not a dependency, and treating it as one would make every such
  // task a one-node cycle.
  let fmt = graph_test_task("fmt", ["src/**"], ["src/**"], [], None)
  let plan = graph_test_plan([fmt])
  let graph = build_action_graph(plan, ".", ["fmt"])
  assert_eq(graph.cycle, None)
  assert_eq(graph.nodes.get("fmt").unwrap().edges.length(), 0)
  assert_eq(producers_of_input(graph, "fmt", "src/**"), [])
}

///|
test "a declared dep is not reported as a derived one" {
  // The edge exists either way; what differs is whether `explain`
  // claims to have inferred something the Taskfile already says.
  let gen = graph_test_task("gen", ["src/in.txt"], ["dist/out.txt"], [], None)
  let consume = graph_test_task(
    "consume", ["dist/out.txt"], [], ["gen"], None,
  )
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume"])
  let edges = graph.nodes.get("consume").unwrap().edges
  assert_eq(edges.length(), 1)
  assert_true(edges[0].reason == DeclaredDep)
  assert_eq(inferred_edges_of(graph, "consume").length(), 0)
}

///|
test "a derived edge carries both patterns and a path matching them" {
  let gen = graph_test_task("gen", [], ["dist/**"], [], None)
  let consume = graph_test_task("consume", ["dist/*.js"], [], [], None)
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume", "gen"])
  let inferred = inferred_edges_of(graph, "consume")
  assert_eq(inferred.length(), 1)
  assert_eq(inferred[0].producer, "gen")
  match inferred[0].reason {
    ConsumedArtifact(input, output, witness) => {
      assert_eq(input, "dist/*.js")
      assert_eq(output, "dist/**")
      // The witness has to be a real member of both patterns, or the
      // message it appears in is a guess dressed up as evidence.
      assert_true(glob_match(input, witness))
      assert_true(glob_match(output, witness))
    }
    DeclaredDep => fail("expected a derived edge")
  }
}

///|
test "a cycle made only of derived edges is reported, naming both edges" {
  let a = graph_test_task("a", ["b-out/**"], ["a-out"], [], None)
  let b = graph_test_task("b", ["a-out/**"], ["b-out"], [], None)
  let plan = graph_test_plan([a, b])
  let graph = build_action_graph(plan, ".", ["a", "b"])
  let message = match graph.cycle {
    Some(m) => m
    None => {
      fail("expected a cycle")
      ""
    }
  }
  assert_true(message.contains("is part of a cycle"))
  // Without the reasons the reader would go looking for a `deps` line
  // that does not exist.
  assert_true(message.contains("`a` reads `b-out/**`"))
  assert_true(message.contains("`b` reads `a-out/**`"))
}

///|
test "a declared-deps cycle is still reported" {
  let a = graph_test_task("a", [], [], ["b"], None)
  let b = graph_test_task("b", [], [], ["a"], None)
  let plan = graph_test_plan([a, b])
  let graph = build_action_graph(plan, ".", ["a"])
  assert_true(graph.cycle is Some(_))
  assert_true(graph.cycle.unwrap().contains("(deps)"))
}

///|
test "inference orders the run set but never widens it" {
  // `consume` reads what `gen` writes, but nothing asked for `gen`.
  // Pulling it in would run a command the user did not request —
  // `deps` is how a Taskfile says "build this first".
  let gen = graph_test_task("gen", ["src/in.txt"], ["dist/out.txt"], [], None)
  let consume = graph_test_task("consume", ["dist/out.txt"], [], [], None)
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume"])
  assert_eq(graph.order, ["consume"])
  assert_true(graph.nodes.get("gen") is None)
  assert_eq(producers_of_input(graph, "consume", "dist/out.txt"), [])
}

///|
test "the run set is the declared-deps closure, in dependency order" {
  let c = graph_test_task("c", [], [], [], None)
  let b = graph_test_task("b", [], [], ["c"], None)
  let a = graph_test_task("a", [], [], ["b"], None)
  let plan = graph_test_plan([a, b, c])
  assert_eq(run_set_of(plan, ["a"]), ["c", "b", "a"])
  // An unknown name contributes nothing rather than aborting: the
  // caller reports it with the message every other command uses.
  assert_eq(run_set_of(plan, ["nope"]), [])
}

///|
test "declared deps reach transitively" {
  let c = graph_test_task("c", [], [], [], None)
  let b = graph_test_task("b", [], [], ["c"], None)
  let a = graph_test_task("a", [], [], ["b"], None)
  let plan = graph_test_plan([a, b, c])
  assert_true(declared_deps_reach(plan, "a", "c"))
  assert_false(declared_deps_reach(plan, "c", "a"))
}

///|
test "patterns from a workdir task are matched at the repo root" {
  // The producer writes `js/dist/**` and the consumer, rooted in `js/`,
  // reads `dist/app.js`. As written the two patterns share no text;
  // they name the same file only once both are re-rooted.
  let gen = graph_test_task("gen", [], ["js/dist/**"], [], None)
  let consume = graph_test_task(
    "consume", ["dist/app.js"], [], [], Some("js"),
  )
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume", "gen"])
  assert_eq(producers_of_input(graph, "consume", "js/dist/app.js"), ["gen"])
  assert_true(
    order_index(graph.order, "gen") < order_index(graph.order, "consume"),
  )
}

///|
test "consumed artifacts are part of the action key" {
  // The point of the field: a task whose declared inputs did not
  // change still gets a new key when a dependency's output did.
  let task = graph_test_task("test", ["src/**"], [], ["build"], None)
  let plan = graph_test_plan([task])
  let bare = action_key_of(
    lower_task_to_action(plan, task, [], Map([], capacity=0), [], ""),
  )
  let with_artifact = action_key_of(
    lower_task_to_action(
      plan,
      task,
      [],
      Map([], capacity=0),
      [],
      "",
      consumed_artifacts=[("dist/app.js", "aa")],
    ),
  )
  let changed = action_key_of(
    lower_task_to_action(
      plan,
      task,
      [],
      Map([], capacity=0),
      [],
      "",
      consumed_artifacts=[("dist/app.js", "bb")],
    ),
  )
  assert_not_eq(bare, with_artifact)
  assert_not_eq(with_artifact, changed)
}

///|
test "an artifact digest cannot be forged from a source input path" {
  // `inputs` and `consumed_artifacts` are separate fields precisely so
  // the same (path, digest) pair in one is not the same key as in the
  // other. Without the split, moving a path between the two would be
  // invisible.
  let task = graph_test_task("t", [], [], [], None)
  let plan = graph_test_plan([task])
  let as_input = action_key_of(
    lower_task_to_action(
      plan, task, [("dist/app.js", "aa")], Map([], capacity=0), [], "",
    ),
  )
  let as_artifact = action_key_of(
    lower_task_to_action(
      plan,
      task,
      [],
      Map([], capacity=0),
      [],
      "",
      consumed_artifacts=[("dist/app.js", "aa")],
    ),
  )
  assert_not_eq(as_input, as_artifact)
}
