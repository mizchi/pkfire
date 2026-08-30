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
  /// Build settings, sorted by key. An array rather than a map so two
  /// configurations compare and hash the same however the Taskfile's
  /// mapping happened to be ordered — the same reason provider env and
  /// toolchain fields are sorted before they reach the key.
  settings : Array[(String, String)]
} derive(Eq)

///|
fn Configuration::host() -> Configuration {
  Configuration::{ target_platform: "", settings: [] }
}

///|
/// `settings` as a lookup, for merging.
fn Configuration::setting_map(self : Configuration) -> Map[String, String] {
  let out : Map[String, String] = Map([], capacity=self.settings.length())
  for pair in self.settings {
    out[pair.0] = pair.1
  }
  out
}

///|
/// A configuration from a settings lookup, canonically ordered.
fn config_with_settings(
  target_platform : String,
  settings : Map[String, String],
) -> Configuration {
  let keys : Array[String] = []
  for k, _ in settings {
    keys.push(k)
  }
  keys.sort()
  let sorted : Array[(String, String)] = []
  for k in keys {
    sorted.push((k, settings.get(k).unwrap()))
  }
  Configuration::{ target_platform, settings: sorted }
}

///|
/// `parent` with `task`'s own declarations layered on top.
///
/// Merged per key rather than replaced: a task inherits every setting
/// from whoever depends on it and overrides only the ones it names, so
/// a host tool can pin the one setting it cares about without having to
/// restate the rest.
fn merge_settings(
  parent : Configuration,
  task : Task,
) -> Map[String, String] {
  let merged = parent.setting_map()
  for k, v in task.config {
    merged[k] = v
  }
  merged
}

///|
/// What `task` is built with, given the configuration that reached it.
///
/// A declared `targetPlatform` *replaces* the inherited one — a host
/// tool inside a cross build is not building for arm64 in any sense.
/// Settings merge per key, so the same tool inherits every setting it
/// does not name.
fn effective_config(inherited : Configuration, task : Task) -> Configuration {
  let platform = match task.target_platform {
    Some(p) => p
    None => inherited.target_platform
  }
  config_with_settings(platform, merge_settings(inherited, task))
}

///|
/// The configuration a task declares for itself, ignoring the graph.
///
/// What a caller without a run set has to fall back to: a bare
/// `describe` has no consumers to inherit from, and reading the
/// declaration is what it did before transitions existed.
fn Configuration::declared(task : Task) -> Configuration {
  config_with_settings(task.target_platform.unwrap_or(""), task.config)
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
  // The run's default configuration, from `--config`. Applies to every
  // root and flows down from there, so a setting given on the command
  // line reaches the whole run — while a task's own declaration still
  // wins for its subtree, which is what makes pinning meaningful.
  seed~ : Configuration = Configuration::host(),
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
    // What reached this task, or nothing if it is a root.
    let inherited = reached.get(name)
    let base = match inherited {
      Some(r) => r.config
      None => seed
    }
    // A task's own declarations layer on top of what reached it, and
    // everything below inherits the result. A declared platform
    // *replaces* the inherited one; settings merge per key, so a host
    // tool can pin the one setting it cares about without restating the
    // rest. That is what lets a codegen tool inside a cross build pin
    // itself to the host.
    let declares_platform = task.target_platform is Some(_)
    let config = effective_config(base, task)
    // The origin is the task an author would edit. A task that declared
    // something is its own origin; otherwise the credit stays with
    // whoever handed the configuration down.
    let origin = if declares_platform || task.config.length() > 0 {
      name
    } else {
      match inherited {
        Some(r) => r.origin
        None => name
      }
    }
    let here = ConfigReach::{ config, origin }
    reached[name] = here
    // Only a configuration someone actually asked for transitions
    // anything. A task that declares nothing and inherited nothing has
    // no opinion to pass down, and treating its default as one would
    // make the feature unusable in the shape most Taskfiles have: a
    // `ci` umbrella over everything would force the execution platform
    // onto every dependency, and any cross-built task sharing one would
    // conflict with it.
    if config == Configuration::host() {
      continue
    }
    // Hand it to everything this task depends on.
    match graph.nodes.get(name) {
      Some(node) =>
        for edge in node.edges {
          let producer = edge.producer
          match reached.get(producer) {
            // Reached twice. Whether that is a conflict depends on what
            // the producer itself declares: two consumers disagreeing
            // about a setting the producer pins is not a disagreement
            // about anything, so the two are compared *after* its own
            // declarations are applied — which is exactly what it will
            // be built with either way.
            Some(existing) => {
              let settled = match plan.tasks.get(producer) {
                Some(p) =>
                  effective_config(existing.config, p) !=
                  effective_config(here.config, p)
                // Not in the plan, so nothing can override the
                // difference.
                None => existing.config != here.config
              }
              if settled && conflict is None {
                conflict = Some(ConfigConflict::{
                  task: producer,
                  first: existing,
                  second: here,
                })
              }
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
/// The environment variable a build setting reaches the command as.
///
/// Prefixed so a setting cannot shadow a param (`$MODE`) or an `env`
/// entry, and uppercased the way params already are.
fn config_env_name(key : String) -> String {
  "PKF_CONFIG_" + upcase(key)
}

///|
/// How a configuration reads in a diagnostic.
///
/// Only the parts that carry information: a run with no build settings
/// should not have an empty brace pair in its error message, and a run
/// with several should not make the reader diff two long strings to
/// find the one that differs.
fn config_label(config : Configuration) -> String {
  let platform = if config.target_platform.length() == 0 {
    "the execution platform (" + exec_platform() + ")"
  } else {
    config.target_platform
  }
  if config.settings.length() == 0 {
    return platform
  }
  let parts : Array[String] = []
  for pair in config.settings {
    parts.push(pair.0 + "=" + pair.1)
  }
  platform + " with " + join_with(parts, ", ")
}

///|
/// The settings the two sides disagree about, `key: a vs b`.
///
/// Named individually because the interesting part of a conflict
/// between two long configurations is the one key that differs, and
/// asking the reader to diff two rendered configurations by eye is how
/// a clear error becomes an unread one.
fn config_differences(
  first : Configuration,
  second : Configuration,
) -> Array[String] {
  let a = first.setting_map()
  let b = second.setting_map()
  let keys : Array[String] = []
  let seen : Map[String, Bool] = Map([], capacity=8)
  for pair in first.settings {
    if !seen.contains(pair.0) {
      seen[pair.0] = true
      keys.push(pair.0)
    }
  }
  for pair in second.settings {
    if !seen.contains(pair.0) {
      seen[pair.0] = true
      keys.push(pair.0)
    }
  }
  keys.sort()
  let out : Array[String] = []
  for key in keys {
    let left = a.get(key).unwrap_or("(unset)")
    let right = b.get(key).unwrap_or("(unset)")
    if left != right {
      out.push(key + ": " + left + " vs " + right)
    }
  }
  out
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
  let platforms_differ = conflict.first.config.target_platform !=
    conflict.second.config.target_platform
  // Named by what actually differs, because "two configurations" sends
  // the reader looking at the platform when the disagreement is over a
  // build setting.
  let what = if platforms_differ {
    "two target platforms"
  } else {
    "two build configurations"
  }
  let mut message = "task `\{conflict.task}` is needed for \{what} in one run: " +
    "\{first} (via `\{conflict.first.origin}`) and \{second} (via `\{conflict.second.origin}`)."
  let diffs = config_differences(conflict.first.config, conflict.second.config)
  if diffs.length() > 0 {
    message = message + "\n  Differs on: " + join_with(diffs, "; ")
  }
  let pin = if platforms_differ { "targetPlatform" } else { "config" }
  message +
  "\n  Both would write the same `outputs`, so pkfire cannot build it twice yet." +
  "\n  Either run them separately, or give `\{conflict.task}` its own `\{pin}`" +
  "\n  so it pins one configuration regardless of who depends on it."
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
