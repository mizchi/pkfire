// ---------------------------------------------------------------------------
// Configuration transitions.
//
// `targetPlatform` says what a task builds *for*, and it selects which
// compiler a `Toolchain` resolves to and what reaches the action key.
// Until now it was read straight off the task, which means it stopped
// at the task that declared it: a cross build's dependencies were
// resolved and keyed for the host.
//
//     app  targetPlatform = "linux/arm64"   →  cc -> aarch64-linux-gnu-gcc
//     lib  (depended on by app)             →  cc -> the host compiler
//
// `lib` is part of the arm64 build. Keying it for the host is wrong in
// both directions: it shares an entry with a host build of `lib` that
// used a different compiler, and it will not share one with another
// arm64 build that should hit.
//
// So the configuration propagates down the graph, which is Bazel's
// transition in its simplest form: a target's identity is the task
// *and* the configuration it was reached in. A task that declares its
// own `targetPlatform` pins itself and everything under it — that is
// what a host tool inside a cross build needs.
//
// What is deliberately not built yet is the other half of a real
// ConfiguredTarget: a task reached in two different configurations
// should appear twice, with separate outputs. pkfire has no
// per-configuration output root, so two configurations of one task
// would write the same paths and race. Until outputs are rooted per
// configuration, that case is refused by name rather than silently
// built once and used for both — which is what happens today.
// ---------------------------------------------------------------------------

///|
/// The configuration a task is built in.
///
/// One field today, and named rather than passed around as a bare
/// string because the next things to land here — configuration flags,
/// an execution platform distinct from the host — belong beside it and
/// have to reach the action key the same way.
struct Configuration {
  /// `<os>/<arch>` this task builds for, or "" for the execution
  /// platform.
  target_platform : String
} derive(Eq)

///|
fn Configuration::host() -> Configuration {
  Configuration::{ target_platform: "" }
}

///|
/// The configuration a task declares for itself, ignoring the graph.
///
/// What a caller without a run set has to fall back to: a bare
/// `describe` has no consumers to inherit from, and reading the
/// declaration is what it did before transitions existed.
fn Configuration::declared(task : Task) -> Configuration {
  Configuration::{ target_platform: task.target_platform.unwrap_or("") }
}

///|
/// The resolved configuration if the caller has one, else the task's
/// own declaration.
fn config_or_declared(config : Configuration?, task : Task) -> Configuration {
  match config {
    Some(c) => c
    None => Configuration::declared(task)
  }
}

///|
/// How a task ended up in a configuration, for the conflict message.
///
/// A conflict names two paths through the graph, and "app wants arm64"
/// is only half an answer when `app` is six hops above the task that
/// actually differs.
struct ConfigReach {
  config : Configuration
  /// The task that declared this configuration, which is the task an
  /// author would edit to resolve the conflict.
  origin : String
}

///|
/// Two ways one task was reached, in configurations that disagree.
struct ConfigConflict {
  task : String
  first : ConfigReach
  second : ConfigReach
}

///|
/// The configuration each task in the run set is built in.
///
/// Walks the same edges the action graph does — declared `deps` and the
/// artifact edges derived from what a task reads — so a consumer that
/// never named its producer in `deps` still transitions it.
///
/// Only a declared `targetPlatform` transitions anything. A task
/// without one is built for the execution platform *unless* something
/// above it says otherwise, so a task named directly on the command
/// line alongside a cross build is built the way that cross build needs
/// it — there is one `outputs` path and only one answer that satisfies
/// both. Running it on its own gives the execution platform, as before.
///
/// Returns the first conflict found rather than a partial map: a run
/// where one task's configuration is ambiguous has no correct answer
/// for it, and proceeding with either would produce a cache entry that
/// claims to be both.
fn resolve_configurations(
  plan : Plan,
  graph : ActionGraph,
) -> (Map[String, Configuration], ConfigConflict?) {
  let reached : Map[String, ConfigReach] = Map(
    [],
    capacity=graph.order.length(),
  )
  // Consumers before producers: `graph.order` is topological over
  // producer → consumer, so walking it backwards visits a task only
  // after everything that depends on it. That is the direction a
  // transition travels.
  let mut conflict : ConfigConflict? = None
  let order = graph.order
  for i = order.length() - 1; i >= 0; i = i - 1 {
    let name = order[i]
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    // A task that declares its own platform is the origin of a
    // transition: it overrides whatever reached it, and everything
    // below inherits the new one. That is what lets a codegen tool
    // inside a cross build pin itself to the host.
    let own = match task.target_platform {
      Some(p) => Some(ConfigReach::{
        config: Configuration::{ target_platform: p },
        origin: name,
      })
      None => None
    }
    let here = match own {
      Some(r) => r
      None =>
        match reached.get(name) {
          Some(r) => r
          // A root nothing depends on, with nothing declared: the
          // execution platform.
          None => ConfigReach::{ config: Configuration::host(), origin: name }
        }
    }
    reached[name] = here
    // Only an explicit configuration transitions anything. A task that
    // declares no `targetPlatform` has no opinion to pass down, and
    // treating its default as one would make the feature unusable in
    // the shape most Taskfiles have: a `ci` umbrella over everything
    // would force the execution platform onto every dependency, and
    // any cross-built task sharing one would conflict with it.
    if here.config.target_platform.length() == 0 {
      continue
    }
    // Hand it to everything this task depends on.
    match graph.nodes.get(name) {
      Some(node) =>
        for edge in node.edges {
          let producer = edge.producer
          // A producer that pins itself is not transitioned by anyone.
          match plan.tasks.get(producer) {
            Some(p) if p.target_platform is Some(_) => continue
            _ => ()
          }
          match reached.get(producer) {
            Some(existing) =>
              if existing.config != here.config && conflict is None {
                conflict = Some(ConfigConflict::{
                  task: producer,
                  first: existing,
                  second: here,
                })
              }
            None => reached[producer] = ConfigReach::{ ..here, }
          }
        }
      None => ()
    }
  }
  let out : Map[String, Configuration] = Map([], capacity=reached.length())
  for name, reach in reached {
    out[name] = reach.config
  }
  (out, conflict)
}

///|
/// How a configuration reads in a diagnostic.
fn config_label(config : Configuration) -> String {
  if config.target_platform.length() == 0 {
    "the execution platform (" + exec_platform() + ")"
  } else {
    config.target_platform
  }
}

///|
/// The message for a task wanted in two configurations at once.
///
/// Spelled out rather than "conflicting platforms" because the fix is
/// not obvious from the names alone: either the two consumers agree, or
/// the shared task pins itself — and the second is usually what a host
/// tool wants.
fn config_conflict_message(conflict : ConfigConflict) -> String {
  let first = config_label(conflict.first.config)
  let second = config_label(conflict.second.config)
  "task `\{conflict.task}` is needed for two target platforms in one run: " +
  "\{first} (via `\{conflict.first.origin}`) and \{second} (via `\{conflict.second.origin}`).\n" +
  "  Both would write the same `outputs`, so pkfire cannot build it twice yet.\n" +
  "  Either run them separately, or give `\{conflict.task}` its own `targetPlatform`\n" +
  "  so it pins one configuration regardless of who depends on it."
}

///|
/// The configuration for one task, defaulting to the execution
/// platform.
fn config_of(
  configs : Map[String, Configuration],
  name : String,
) -> Configuration {
  configs.get(name).unwrap_or(Configuration::host())
}
