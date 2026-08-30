// Rendering the task graph for people rather than for tooling.
//
// `pkf graph --json` has always emitted `{tasks, edges}`, which is what
// a program wants. What a person wants is a picture, and the Go
// implementation had `--format dot|mermaid|tree` for exactly that. The
// MoonBit port dropped them and the README kept advertising them, so
// the documented `pkf graph | dot -Tsvg` pipeline could not have
// worked. This restores the formats.
//
// The visual formats show both kinds of edge the runner honours:
// declared `deps`, and the ones analysis derives from one task reading
// what another declares as output. A diagram that showed only half the
// ordering constraints would be worse than none — the reader would use
// it to reason about a build whose real shape is different. `--json` is
// left alone: it is a machine contract, and adding a field to it would
// break every consumer to serve a human-readable concern.

///|
/// How to render the graph.
enum GraphFormat {
  /// Indented dependency tree; the default, and what `pkf graph` has
  /// printed since the port.
  GraphTree
  /// Graphviz DOT, for `pkf graph --format dot | dot -Tsvg`.
  GraphDot
  /// Mermaid flowchart, which GitHub renders inline in a comment.
  GraphMermaid
  /// `{tasks, edges}`; also reachable as the older `--json`.
  GraphJson
} derive(Eq)

///|
fn parse_graph_format(value : String) -> GraphFormat? {
  match value {
    "tree" => Some(GraphTree)
    "dot" => Some(GraphDot)
    "mermaid" => Some(GraphMermaid)
    "json" => Some(GraphJson)
    _ => None
  }
}

///|
/// One edge of the rendered graph, pointing from the task that must run
/// first to the one that waits for it.
struct GraphEdge {
  from : String
  to : String
  /// Empty for a declared `deps` edge; for a derived one, the output
  /// pattern that links them — which is the answer to "why is this
  /// arrow here?".
  via : String
}

///|
/// The tasks a rendering covers: the visible set, optionally narrowed
/// to one target's dependency closure and to a maximum hop count.
///
/// `--depth` counts edges from the roots, so `--depth=1` is "the task
/// and what it directly needs". Zero is the task alone, which is a
/// legitimate thing to ask for and not the same as omitting the flag.
fn graph_node_set(
  plan : Plan,
  show_all : Bool,
  target : String?,
  depth : Int?,
) -> Array[String] {
  let visible : Map[String, Bool] = Map([], capacity=plan.tasks.length())
  for task in sorted_visible_tasks(plan, show_all) {
    visible[task.name] = true
  }
  let roots : Array[String] = match target {
    // The target is included whatever its visibility: asking for it by
    // name is a clearer signal of intent than `--all`.
    Some(name) => [name]
    None => {
      let out : Array[String] = []
      for name in plan.task_order {
        if visible.contains(name) {
          out.push(name)
        }
      }
      out
    }
  }
  // Breadth-first so the hop count is the real distance from a root,
  // not whatever a depth-first walk happened to reach first.
  let reached : Map[String, Bool] = Map([], capacity=plan.tasks.length())
  let mut frontier : Array[String] = []
  for name in roots {
    if plan.tasks.get(name) is Some(_) && !reached.contains(name) {
      reached[name] = true
      frontier.push(name)
    }
  }
  let mut hops = 0
  while frontier.length() > 0 {
    if depth is Some(limit) && hops >= limit {
      break
    }
    let next : Array[String] = []
    for name in frontier {
      match plan.tasks.get(name) {
        Some(task) =>
          for dep in task.deps {
            if !reached.contains(dep) && plan.tasks.get(dep) is Some(_) {
              reached[dep] = true
              next.push(dep)
            }
          }
        None => ()
      }
    }
    frontier = next
    hops = hops + 1
  }
  // Declaration order, filtered to what the walk reached. A dependency
  // pulled in by `--target` shows up even when it is internal: hiding
  // an edge's other end would leave an arrow pointing at nothing.
  let out : Array[String] = []
  for name in plan.task_order {
    if reached.contains(name) {
      out.push(name)
    }
  }
  out
}

///|
/// Every edge among `nodes`: declared `deps` first, then the ones
/// analysis derives from artifacts and `deps` does not already cover.
fn graph_edges(
  plan : Plan,
  repo_root : String,
  nodes : Array[String],
) -> Array[GraphEdge] {
  let in_set : Map[String, Bool] = Map([], capacity=nodes.length())
  for name in nodes {
    in_set[name] = true
  }
  let edges : Array[GraphEdge] = []
  let seen : Map[String, Bool] = Map([], capacity=nodes.length() * 2)
  for name in nodes {
    match plan.tasks.get(name) {
      Some(task) =>
        for dep in task.deps {
          let key = dep + "\u{1F}" + name
          if in_set.contains(dep) && !seen.contains(key) {
            seen[key] = true
            edges.push(GraphEdge::{ from: dep, to: name, via: "" })
          }
        }
      None => ()
    }
  }
  // Derived edges come from the same analysis the runner schedules
  // with, so the picture matches the execution order rather than the
  // Taskfile's prose.
  let graph = build_action_graph(plan, repo_root, nodes)
  for name in nodes {
    for edge in inferred_edges_of(graph, name) {
      let key = edge.producer + "\u{1F}" + name
      if !in_set.contains(edge.producer) || seen.contains(key) {
        continue
      }
      seen[key] = true
      let via = match edge.reason {
        ConsumedArtifact(_, output, _) => output
        DeclaredDep => ""
      }
      edges.push(GraphEdge::{ from: edge.producer, to: name, via })
    }
  }
  edges
}

///|
/// A DOT/Mermaid-safe identifier for a task name.
///
/// Task names may contain `:` `/` `.` and `-`, none of which a Mermaid
/// node id accepts. The label carries the real name, so nothing is lost
/// — but two names must not collapse onto one id, hence the index
/// suffix rather than a bare substitution.
fn graph_node_ids(nodes : Array[String]) -> Map[String, String] {
  let ids : Map[String, String] = Map([], capacity=nodes.length())
  for i, name in nodes {
    let buf = StringBuilder()
    for ch in name {
      if (ch >= 'a' && ch <= 'z') ||
        (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') ||
        ch == '_' {
        buf.write_char(ch)
      } else {
        buf.write_char('_')
      }
    }
    ids[name] = "t" + i.to_string() + "_" + buf.to_string()
  }
  ids
}

///|
/// Escape a string for a DOT double-quoted literal.
fn dot_quote(text : String) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for ch in text {
    if ch == '"' || ch == '\\' {
      buf.write_char('\\')
    }
    buf.write_char(ch)
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Graphviz DOT. `rankdir=LR` because a build reads left to right:
/// sources on the left, the thing you asked for on the right.
fn render_graph_dot(
  plan : Plan,
  nodes : Array[String],
  edges : Array[GraphEdge],
) -> Unit {
  let ids = graph_node_ids(nodes)
  println("digraph pkfire {")
  println("  rankdir=LR;")
  println("  node [shape=box, fontname=\"monospace\"];")
  for name in nodes {
    let id = ids.get(name).unwrap()
    // A deps-only umbrella spawns no process; drawing it like one that
    // does would misrepresent what the build actually executes.
    let shape = match plan.tasks.get(name) {
      Some(task) =>
        if task.service {
          ", shape=ellipse"
        } else if task.cmd.length() == 0 {
          ", shape=note"
        } else {
          ""
        }
      None => ""
    }
    println("  " + id + " [label=" + dot_quote(name) + shape + "];")
  }
  for edge in edges {
    let from = ids.get(edge.from).unwrap()
    let to = ids.get(edge.to).unwrap()
    if edge.via.length() > 0 {
      println(
        "  " +
        from +
        " -> " +
        to +
        " [style=dashed, label=" +
        dot_quote(edge.via) +
        "];",
      )
    } else {
      println("  " + from + " -> " + to + ";")
    }
  }
  println("}")
}

///|
/// Mermaid flowchart, which renders inline in a GitHub comment.
fn render_graph_mermaid(nodes : Array[String], edges : Array[GraphEdge]) -> Unit {
  let ids = graph_node_ids(nodes)
  println("flowchart LR")
  for name in nodes {
    println("  " + ids.get(name).unwrap() + "[" + dot_quote(name) + "]")
  }
  for edge in edges {
    let from = ids.get(edge.from).unwrap()
    let to = ids.get(edge.to).unwrap()
    if edge.via.length() > 0 {
      // A dotted arrow with the output pattern on it: the reader can
      // see both that the edge is derived and what derived it.
      println("  " + from + " -. " + dot_quote(edge.via) + " .-> " + to)
    } else {
      println("  " + from + " --> " + to)
    }
  }
}
