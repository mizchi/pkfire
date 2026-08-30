// Tests for graph rendering.
//
// The node set and the edge set are where a mistake is silent: a
// `--depth` that shows one hop too many still looks like a graph, and a
// diagram missing the derived edges looks like a *correct* graph of a
// build with a different shape. The rendered text itself is checked
// end to end by the `graph-dot` and `graph-mermaid` conformance
// scenarios.

///|
test "`--depth` counts hops from the root" {
  let c = graph_test_task("c", [], [], [], None)
  let b = graph_test_task("b", [], [], ["c"], None)
  let a = graph_test_task("a", [], [], ["b"], None)
  let plan = graph_test_plan([a, b, c])
  // Zero is the target alone — a legitimate question, and not the same
  // as omitting the flag.
  assert_eq(graph_node_set(plan, false, Some("a"), Some(0)), ["a"])
  assert_eq(graph_node_set(plan, false, Some("a"), Some(1)), ["a", "b"])
  assert_eq(graph_node_set(plan, false, Some("a"), Some(2)), ["a", "b", "c"])
  assert_eq(graph_node_set(plan, false, Some("a"), None), ["a", "b", "c"])
}

///|
test "the hop count is the shortest distance, not the walk order" {
  // `d` is one hop from the root as well as three. A depth-first walk
  // that recorded the first depth it reached `d` at could bury it
  // beyond `--depth=1`; breadth-first cannot.
  let d = graph_test_task("d", [], [], [], None)
  let c = graph_test_task("c", [], [], ["d"], None)
  let b = graph_test_task("b", [], [], ["c"], None)
  let a = graph_test_task("a", [], [], ["b", "d"], None)
  let plan = graph_test_plan([a, b, c, d])
  let one_hop = graph_node_set(plan, false, Some("a"), Some(1))
  assert_true(one_hop.contains("d"))
  assert_false(one_hop.contains("c"))
}

///|
test "a target pulls in internal dependencies, and no target hides them" {
  // Asking for a task by name is a clearer signal than `--all`, and an
  // edge whose other end is hidden would point at nothing.
  let hidden = {
    ..graph_test_task("hidden", [], [], [], None),
    visibility: "internal",
  }
  let shown = graph_test_task("shown", [], [], ["hidden"], None)
  let plan = graph_test_plan([shown, hidden])
  assert_eq(graph_node_set(plan, false, Some("shown"), None), [
    "shown", "hidden",
  ])
  // Without a target, an internal task is not a root — but it is still
  // reached as `shown`'s dependency.
  assert_eq(graph_node_set(plan, false, None, None), ["shown", "hidden"])
  assert_eq(graph_node_set(plan, false, None, Some(0)), ["shown"])
}

///|
test "the rendered graph carries derived edges as well as declared ones" {
  // `pkf graph` showed only `deps`, while the runner also orders by
  // artifacts. A picture of half the ordering constraints is worse
  // than none: the reader uses it to reason about a build whose real
  // shape is different.
  let gen = graph_test_task("gen", ["src/in.txt"], ["dist/out.txt"], [], None)
  let consume = graph_test_task("consume", ["dist/out.txt"], [], [], None)
  let plan = graph_test_plan([gen, consume])
  let edges = graph_edges(plan, ".", ["gen", "consume"])
  assert_eq(edges.length(), 1)
  assert_eq(edges[0].from, "gen")
  assert_eq(edges[0].to, "consume")
  // The output pattern answers "why is this arrow here?".
  assert_eq(edges[0].via, "dist/out.txt")
}

///|
test "a declared dep is drawn once, not twice" {
  // `consume` both declares `deps { gen }` and reads what `gen`
  // writes. Two arrows between the same pair would suggest two
  // constraints where there is one.
  let gen = graph_test_task("gen", [], ["dist/out.txt"], [], None)
  let consume = graph_test_task(
    "consume", ["dist/out.txt"], [], ["gen"], None,
  )
  let plan = graph_test_plan([gen, consume])
  let edges = graph_edges(plan, ".", ["gen", "consume"])
  assert_eq(edges.length(), 1)
  // Declared wins the label: the Taskfile says it outright, so calling
  // it derived would credit inference for something written down.
  assert_eq(edges[0].via, "")
}

///|
test "an edge to a node outside the rendering is dropped" {
  // `--depth` and `--target` narrow the node set; an arrow to a task
  // that is not drawn would dangle.
  let c = graph_test_task("c", [], [], [], None)
  let b = graph_test_task("b", [], [], ["c"], None)
  let a = graph_test_task("a", [], [], ["b"], None)
  let plan = graph_test_plan([a, b, c])
  let edges = graph_edges(plan, ".", ["a", "b"])
  assert_eq(edges.length(), 1)
  assert_eq(edges[0].from, "b")
  assert_eq(edges[0].to, "a")
}

///|
test "node ids survive names DOT and Mermaid cannot spell" {
  // Task names may contain `:` `/` `.` and `-`; a Mermaid node id may
  // not. Two names must still not collapse onto one id.
  let ids = graph_node_ids(["test:unit", "test/unit", "build"])
  assert_eq(ids.get("test:unit"), Some("t0_test_unit"))
  assert_eq(ids.get("test/unit"), Some("t1_test_unit"))
  assert_eq(ids.get("build"), Some("t2_build"))
}

///|
test "DOT string literals escape what would end them early" {
  assert_eq(dot_quote("plain"), "\"plain\"")
  assert_eq(dot_quote("say \"hi\""), "\"say \\\"hi\\\"\"")
  assert_eq(dot_quote("a\\b"), "\"a\\\\b\"")
}

///|
test "format names map to formats, and anything else is rejected" {
  assert_true(parse_graph_format("tree") == Some(GraphTree))
  assert_true(parse_graph_format("dot") == Some(GraphDot))
  assert_true(parse_graph_format("mermaid") == Some(GraphMermaid))
  assert_true(parse_graph_format("json") == Some(GraphJson))
  assert_true(parse_graph_format("svg") is None)
  assert_true(parse_graph_format("") is None)
}
