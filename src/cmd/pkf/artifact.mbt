// Artifacts and the action graph — the analysis phase.
//
// Before this file, "the graph" was the `deps` list: `topo_sort_for`
// walked declared dependencies and the runner executed the result in
// order. Everything a task consumed had to be spelled twice — once as
// `deps { build }` so it ran first, and again as `inputs { "dist/**" }`
// so the action key could see what it read — and nothing checked that
// the two agreed. Omitting the second is silent and unsound: the
// consumer's key is blind to the very files the producer just rewrote,
// so it hits a stale entry. Omitting the first is silent and racy: the
// consumer reads whatever happens to be on disk.
//
// The fix is Bazel's: make the *file* the edge. A declared `outputs`
// pattern makes its task the producer of those paths; another task
// whose `inputs` reach into that region is its consumer, and the edge
// between them is derived, not declared. Two things follow from one
// model:
//
//   - **Order.** A consumer runs after the actions that produce what it
//     reads, whether or not anybody wrote `deps`.
//   - **Key soundness.** Files produced by an action this one depends
//     on are hashed into its key as `consumed_artifacts`, so a
//     producer whose output changed cannot leave a downstream hit
//     standing.
//
// The graph is built over the run set only: inference orders and keys
// the actions that were going to run anyway, and never drags an
// unrequested task in. `deps` remains the way to say "build this
// first"; inference is what makes the ordering and the key agree with
// it.

///|
/// A file, or set of files, an action reads or writes.
///
/// The distinction that matters is provenance: a `SourceArtifact` is
/// checked in and its content is an input to the build, while a
/// `GeneratedArtifact` is the output of another action in this graph
/// and its content is a *result* — which is why consuming one has to
/// create an edge to whatever produced it.
enum Artifact {
  /// A pattern matching files nothing in the graph produces.
  SourceArtifact(String)
  /// A pattern that reaches into `String`'s declared outputs — the
  /// second field is the producing task's name.
  GeneratedArtifact(String, String)
} derive(Eq)

///|
/// Why one action must run before another.
enum EdgeReason {
  /// The Taskfile said so: `deps { producer }`.
  DeclaredDep
  /// Derived: the consumer's input pattern (first field) reaches into
  /// the producer's output pattern (second field). The third field is
  /// a concrete path in both, which is what makes the inference
  /// reviewable rather than a claim.
  ConsumedArtifact(String, String, String)
} derive(Eq)

///|
/// One edge of the action graph, pointing at the action that must run
/// first.
struct ActionEdge {
  producer : String
  reason : EdgeReason
}

///|
/// One node: an action, its provenance-tagged inputs, and its edges.
///
/// Today a node is exactly one Task, because `lower_task_to_action`
/// lowers one Task into one `SpawnAction`. When lowering produces
/// several actions per Task, this is the type that grows a list of
/// descriptors — the graph, the ordering and the key already speak
/// node, not Task.
struct ActionNode {
  /// Repo-relative input patterns, each tagged with its producer when
  /// the graph has one.
  inputs : Array[Artifact]
  /// Repo-relative output patterns this action claims.
  outputs : Array[String]
  /// Actions that must run first, declared and derived.
  edges : Array[ActionEdge]
}

///|
/// The analysis result: every action in the run set, in an order that
/// respects both declared and derived edges.
struct ActionGraph {
  nodes : Map[String, ActionNode]
  /// Topological order. Ties break on the declared task order so a run
  /// is reproducible.
  order : Array[String]
  /// Set when the edges contain a cycle, holding the message that
  /// explains it. Analysis reports rather than exits so `pkf lint` can
  /// list a cycle among its findings; the runner is what turns it into
  /// a failure, since no order it could pick would be right.
  cycle : String?
}

///|
/// Repo-relative output patterns of a task, in the form artifact
/// matching needs.
///
/// A declared output names either a file or a directory, and the
/// Taskfile does not say which. `outputs { "dist" }` almost always
/// means "everything under dist", so each pattern contributes both
/// itself and its subtree; without the subtree form, a consumer
/// reading `dist/app.js` would not match a producer declaring `dist`.
/// A pattern that already ends in `**` covers its own subtree and is
/// left alone.
fn task_artifact_output_patterns(
  repo_root : String,
  task : Task,
) -> Array[String] {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => repo_root
  }
  let absolute_repo = absolute_lexical_path(repo_root, cwd)
  let task_root = match task.workdir {
    Some(workdir) => absolute_lexical_path(workdir, absolute_repo)
    None => absolute_repo
  }
  let patterns : Array[String] = []
  let seen : Map[String, Bool] = Map([], capacity=task.outputs.length() * 2)
  fn add(pattern : String) -> Unit {
    if pattern.length() > 0 && !seen.contains(pattern) {
      seen[pattern] = true
      patterns.push(pattern)
    }
  }

  for output in task.outputs {
    let absolute_output = absolute_lexical_path(output, task_root)
    match path_relative_to(absolute_repo, absolute_output) {
      Some(relative) => {
        let base = if relative.length() == 0 { "**" } else { relative }
        add(base)
        if !base.has_suffix("**") {
          add(base + "/**")
        }
      }
      None => ()
    }
  }
  patterns
}

///|
/// Tasks reachable from `targets` through declared `deps` — the set a
/// run would execute. Inference operates inside this set and never
/// widens it: adding a task to a run because one of its output globs
/// happened to overlap an input glob would run a command nobody asked
/// for.
fn run_set_of(plan : Plan, targets : Array[String]) -> Array[String] {
  let seen : Map[String, Bool] = Map([], capacity=plan.tasks.length())
  let out : Array[String] = []
  fn visit(name : String) -> Unit {
    if seen.contains(name) {
      return
    }
    seen[name] = true
    match plan.tasks.get(name) {
      Some(task) => {
        for dep in task.deps {
          visit(dep)
        }
        out.push(name)
      }
      None => ()
    }
  }

  for target in targets {
    visit(target)
  }
  out
}

///|
/// Build the action graph for a run of `targets`.
///
/// Declared `deps` become edges as they always did; on top of them,
/// every (consumer input pattern, producer output pattern) pair whose
/// globs share a path becomes a derived edge. A task never consumes
/// its own outputs — a `fmt` task that rewrites the files it reads is
/// a fixpoint, not a cycle.
fn build_action_graph(
  plan : Plan,
  repo_root : String,
  targets : Array[String],
) -> ActionGraph {
  let members = run_set_of(plan, targets)
  let in_set : Map[String, Bool] = Map([], capacity=members.length())
  for name in members {
    in_set[name] = true
  }
  // Producer index: repo-relative output patterns per member task.
  let produced : Map[String, Array[String]] = Map(
    [],
    capacity=members.length(),
  )
  for name in members {
    match plan.tasks.get(name) {
      Some(task) => produced[name] = task_artifact_output_patterns(repo_root, task)
      None => ()
    }
  }
  let nodes : Map[String, ActionNode] = Map([], capacity=members.length())
  for name in members {
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    let edges : Array[ActionEdge] = []
    let seen_edge : Map[String, Bool] = Map([], capacity=8)
    for dep in task.deps {
      if in_set.contains(dep) && !seen_edge.contains(dep) {
        seen_edge[dep] = true
        edges.push(ActionEdge::{ producer: dep, reason: DeclaredDep })
      }
    }
    // Derived edges. Each input pattern is checked against every other
    // member's outputs, and *every* task that overlaps it is a
    // producer: `bundle` reading `dist/**` depends on both the task
    // writing `dist/js/**` and the one writing `dist/css/**`, and
    // stopping at the first would order it after only one of them.
    // Within a single producer the first overlapping output pattern
    // supplies the witness, since one concrete path is enough to show
    // the overlap is real.
    let inputs : Array[Artifact] = []
    for pattern in task_watch_input_patterns(repo_root, task) {
      let mut generated = false
      for other in members {
        if other == name {
          continue
        }
        let outputs = match produced.get(other) {
          Some(o) => o
          None => continue
        }
        let mut matched_output : String? = None
        let mut witness = ""
        for output in outputs {
          match glob_intersection_witness(pattern, output) {
            Some(path) => {
              matched_output = Some(output)
              witness = path
              break
            }
            None => ()
          }
        }
        match matched_output {
          Some(output) => {
            generated = true
            inputs.push(GeneratedArtifact(pattern, other))
            // A declared dep already orders these two; the derived
            // edge only records the reason when it is the sole one, so
            // `explain` does not claim to have inferred what the
            // Taskfile already says.
            if !seen_edge.contains(other) {
              seen_edge[other] = true
              edges.push(ActionEdge::{
                producer: other,
                reason: ConsumedArtifact(pattern, output, witness),
              })
            }
          }
          None => ()
        }
      }
      if !generated {
        inputs.push(SourceArtifact(pattern))
      }
    }
    nodes[name] = ActionNode::{
      inputs,
      outputs: produced.get(name).unwrap_or([]),
      edges,
    }
  }
  let (order, cycle) = topo_sort_action_graph(nodes, members)
  ActionGraph::{ nodes, order, cycle }
}

///|
/// Topological order over declared and derived edges.
///
/// `members` is the declared-deps order, which is already topological
/// for the declared edges; visiting in that order makes ties break
/// predictably, so two runs of the same Taskfile schedule identically.
fn topo_sort_action_graph(
  nodes : Map[String, ActionNode],
  members : Array[String],
) -> (Array[String], String?) {
  let visited : Map[String, Bool] = Map([], capacity=members.length())
  let on_stack : Map[String, Bool] = Map([], capacity=members.length())
  let stack_order : Array[String] = []
  let order : Array[String] = []
  let mut cycle : String? = None
  fn visit(name : String) -> Unit {
    if visited.contains(name) {
      return
    }
    if on_stack.contains(name) {
      // Report the first cycle and keep going: the order that comes
      // back drops the back edge, which is enough for a linter to
      // finish its other checks. The runner refuses it.
      if cycle is None {
        cycle = Some(action_cycle_message(nodes, stack_order, name))
      }
      return
    }
    on_stack[name] = true
    stack_order.push(name)
    match nodes.get(name) {
      Some(node) =>
        for edge in node.edges {
          visit(edge.producer)
        }
      None => ()
    }
    let _ = on_stack.remove(name)
    let _ = stack_order.pop()
    visited[name] = true
    order.push(name)
  }

  for name in members {
    visit(name)
  }
  (order, cycle)
}

///|
/// Explain a cycle in terms of the edges that formed it.
///
/// A cycle made only of declared deps is the error `topo_sort_for`
/// always reported. A cycle that needed a derived edge is new, and
/// saying only "cycle" would leave the reader looking for a `deps`
/// line that does not exist — so each derived edge names the input
/// pattern, the output pattern, and a path both match.
fn action_cycle_message(
  nodes : Map[String, ActionNode],
  stack_order : Array[String],
  repeated : String,
) -> String {
  let sb = StringBuilder()
  sb.write_string("task `\{repeated}` is part of a cycle:")
  let mut started = false
  let cycle : Array[String] = []
  for name in stack_order {
    if name == repeated {
      started = true
    }
    if started {
      cycle.push(name)
    }
  }
  cycle.push(repeated)
  for i in 0..<(cycle.length() - 1) {
    let consumer = cycle[i]
    let producer = cycle[i + 1]
    let mut why = ""
    match nodes.get(consumer) {
      Some(node) =>
        for edge in node.edges {
          if edge.producer == producer {
            why = match edge.reason {
              DeclaredDep => "  (deps)"
              ConsumedArtifact(input, output, witness) =>
                "  (`\{consumer}` reads `\{input}`, which `\{producer}` " +
                "declares as output `\{output}` — e.g. `\{witness}`)"
            }
            break
          }
        }
      None => ()
    }
    sb.write_string("\n  \{consumer} -> \{producer}" + why)
  }
  sb.write_string(
    "\n  break the cycle by narrowing the patterns, or by moving the " +
    "shared files out of one task's `outputs`",
  )
  sb.to_string()
}

///|
/// The actions that produce `pattern` for this consumer.
///
/// Plural because one pattern can span several producers: `dist/**`
/// covers both the task writing `dist/js/**` and the one writing
/// `dist/css/**`. Empty means the pattern is a source.
///
/// `pattern` is repo-relative — the form `repo_relative_pattern`
/// produces — because that is the form the graph stores.
fn producers_of_input(
  graph : ActionGraph,
  task : String,
  pattern : String,
) -> Array[String] {
  let out : Array[String] = []
  let node = match graph.nodes.get(task) {
    Some(n) => n
    None => return out
  }
  for artifact in node.inputs {
    match artifact {
      GeneratedArtifact(p, producer) =>
        if p == pattern && !out.contains(producer) {
          out.push(producer)
        }
      SourceArtifact(_) => ()
    }
  }
  out
}

///|
/// Derived edges of one action, for reporting. Declared deps are
/// already visible in the Taskfile and in `pkf explain`'s `deps` line;
/// these are the ones the reader cannot see without being told.
fn inferred_edges_of(graph : ActionGraph, task : String) -> Array[ActionEdge] {
  let out : Array[ActionEdge] = []
  match graph.nodes.get(task) {
    Some(node) =>
      for edge in node.edges {
        if edge.reason is ConsumedArtifact(_, _, _) {
          out.push(edge)
        }
      }
    None => ()
  }
  out
}

///|
/// Concrete files this action consumes from its producers, hashed into
/// its key.
///
/// Only files the action does not already hash as a source input are
/// returned: when a consumer declares `inputs { "dist/**" }` those
/// paths are already in `inputs` with the same digests, and listing
/// them twice would say nothing new. What is left is the case this
/// exists for — `deps { build }` with no matching `inputs` line, where
/// the key would otherwise be blind to everything `build` wrote.
///
/// Called after the producers have run, so the paths exist and the
/// digests are of the artifacts this action will actually read.
fn consumed_artifact_hashes(
  graph : ActionGraph,
  repo_root : String,
  task : String,
  own_inputs : Array[(String, String)],
) -> Array[(String, String)] {
  let node = match graph.nodes.get(task) {
    Some(n) => n
    None => return []
  }
  let already : Map[String, Bool] = Map([], capacity=own_inputs.length())
  for pair in own_inputs {
    already[pair.0] = true
  }
  let root = if repo_root.length() == 0 { "." } else { repo_root }
  let collected : Map[String, String] = Map([], capacity=16)
  for edge in node.edges {
    match graph.nodes.get(edge.producer) {
      Some(producer) =>
        for rel in expand_inputs(root, producer.outputs) {
          // `already` is keyed on the consumer's own input paths, which
          // are relative to *its* root. Comparing repo-relative paths
          // against them is only exact when the two roots agree; when
          // they differ the path is kept, and the worst case is one
          // extra digest in the key, not a wrong one.
          if !already.contains(rel) && !collected.contains(rel) {
            collected[rel] = hex_encode(hash_file(join_path(root, rel)))
          }
        }
      None => ()
    }
  }
  let out : Array[(String, String)] = []
  for path in sorted_keys(collected) {
    out.push((path, collected.get(path).unwrap()))
  }
  out
}
