// Providers: what a task hands to the tasks that depend on it.
//
// `deps` has meant one thing since the beginning — run that first. The
// runner derives ordering from it, and (since artifacts became
// first-class) hashes the producer's outputs into the consumer's key.
// What it has never carried is *data*: a consumer that wanted the path
// of the binary its dependency built had to write that path out a
// second time, in its own `cmd`, and keep the two in step by hand.
//
// A provider is that data, declared once by the producer. Two kinds,
// chosen because they are exactly the two things Pkl's own `...spread`
// cannot already express:
//
//   - `executable`, because the path a consumer needs is not the path
//     the producer declared — it has to be re-rooted into the
//     consumer's own working directory, which nobody writes correctly
//     by hand in a monorepo.
//   - `env`, because it is not a file at all.
//
// A consumer's `Files` equivalent is `inputs { ...build.outputs }`,
// which already works and needs no schema.
//
// Everything a provider puts in front of the command goes into the
// action key. That is the whole point of routing it through here rather
// than through the shell: a value the command can read and the key
// cannot see is how a cache goes stale.

///|
/// What one task exposes to its dependents.
struct Providers {
  /// The single runnable artifact, relative to the producing task's own
  /// root. Empty when the task declares none.
  executable : String
  /// Values placed in a dependent's environment.
  env : Map[String, String]
}

///|
fn Providers::empty() -> Providers {
  Providers::{ executable: "", env: Map([], capacity=0) }
}

///|
fn Providers::is_empty(self : Providers) -> Bool {
  self.executable.length() == 0 && self.env.length() == 0
}

///|
/// One resolved provider value, ready to be handed to a consumer.
///
/// `producer` and `kind` are kept because they are what makes the value
/// explicable: `pkf explain` can say *which* dependency put `$PKF_CLI`
/// in the environment, which is the question anyone debugging one asks.
struct ProvidedValue {
  producer : String
  /// Environment variable name the consumer's command sees.
  name : String
  /// The value as the command sees it — for an executable, a path
  /// already re-rooted into the consumer's working directory.
  value : String
  /// `executable` or `env`.
  kind : String
}

///|
/// The environment variable a provider surfaces as.
///
/// `PKF_` prefixed and derived from the producing task's name, so the
/// value's origin is legible at the point of use — `$PKF_BUILD_CLI_EXECUTABLE`
/// says where to look when it is wrong. Task names may contain `:` `/`
/// `.` and `-`, none of which a shell variable name accepts.
fn provider_env_name(task : String, suffix : String) -> String {
  let buf = StringBuilder()
  buf.write_string("PKF_")
  for ch in task {
    if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') {
      buf.write_char(upcase_char(ch))
    } else {
      buf.write_char('_')
    }
  }
  buf.write_char('_')
  buf.write_string(suffix)
  buf.to_string()
}

///|
fn upcase_char(ch : Char) -> Char {
  if ch >= 'a' && ch <= 'z' {
    (ch.to_int() - 32).unsafe_to_char()
  } else {
    ch
  }
}

///|
/// Re-root a producer-relative path into the consumer's working
/// directory.
///
/// Both roots are already absolute-ish paths built by `task_root_of`,
/// so the answer is a relative walk from one to the other. When the two
/// tasks share a root — the common case — this is the declared path
/// unchanged. When they do not, this is the part a Taskfile author
/// cannot write correctly without knowing where the consumer will be
/// invoked from.
fn reroot_path(from_root : String, to_root : String, rel : String) -> String {
  if from_root == to_root {
    return rel
  }
  let from_parts = split_path_parts(from_root)
  let to_parts = split_path_parts(to_root)
  // Drop the shared prefix; what is left of `to_parts` is how far up to
  // climb, and what is left of `from_parts` is the way back down.
  let mut common = 0
  while common < from_parts.length() &&
        common < to_parts.length() &&
        from_parts[common] == to_parts[common] {
    common = common + 1
  }
  let buf = StringBuilder()
  for _ in common..<to_parts.length() {
    buf.write_string("../")
  }
  for i in common..<from_parts.length() {
    buf.write_string(from_parts[i])
    buf.write_string("/")
  }
  buf.write_string(rel)
  buf.to_string()
}

///|
/// Path components, with `.` and empty segments dropped.
fn split_path_parts(path : String) -> Array[String] {
  let out : Array[String] = []
  for segment in path.split("/") {
    let seg = segment.to_owned()
    if seg.length() > 0 && seg != "." {
      out.push(seg)
    }
  }
  out
}

///|
/// Every provider value `task`'s direct dependencies hand it, in
/// declaration order.
///
/// Direct only. A provider that travelled two hops would appear in the
/// environment of a task that never named the producer, which is a
/// surprise rather than a convenience — a task that wants to pass
/// something along declares it itself.
///
/// A dependency outside the plan contributes nothing rather than
/// failing: the same tolerance the rest of the graph code has for a
/// `deps` entry naming a task that is not there.
fn provided_values(
  plan : Plan,
  repo_root : String,
  task : Task,
) -> Array[ProvidedValue] {
  let out : Array[ProvidedValue] = []
  let consumer_root = task_root_of(repo_root, task)
  for dep_name in task.deps {
    let dep = match plan.tasks.get(dep_name) {
      Some(d) => d
      None => continue
    }
    if dep.provides.is_empty() {
      continue
    }
    let producer_root = task_root_of(repo_root, dep)
    if dep.provides.executable.length() > 0 {
      out.push(ProvidedValue::{
        producer: dep_name,
        name: provider_env_name(dep_name, "EXECUTABLE"),
        value: reroot_path(
          producer_root, consumer_root, dep.provides.executable,
        ),
        kind: "executable",
      })
    }
    // Sorted, so the action key does not depend on Pkl's mapping order.
    let keys : Array[String] = []
    for key, _ in dep.provides.env {
      keys.push(key)
    }
    keys.sort_by(fn(a, b) { lex_cmp(a, b) })
    for key in keys {
      out.push(ProvidedValue::{
        producer: dep_name,
        name: key,
        value: dep.provides.env.get(key).unwrap(),
        kind: "env",
      })
    }
  }
  out
}

///|
/// Provider values as an environment overlay, in the order they should
/// be applied.
///
/// They go into the command's environment like any other variable, and
/// therefore into the action key like any other variable: the merged
/// overlay is already a field of the descriptor, so a provider whose
/// value changes is a miss without the IR needing a new field for it.
/// The bytes behind an `executable` are covered separately — the
/// producer's outputs are hashed into this action's key as consumed
/// artifacts.
///
/// The re-rooted path is safe to hash because the two roots share the
/// repository prefix, which cancels: what is left is a walk between two
/// directories the Taskfile itself names. (An absolute `workdir` is the
/// exception, and it already puts an absolute path in the descriptor's
/// `working_directory`.)
fn provider_env_overlay(values : Array[ProvidedValue]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for value in values {
    out.push((value.name, value.value))
  }
  out
}

///|
/// The first provider declaration that does not describe something the
/// producing task actually makes.
///
/// An `executable` no `outputs` pattern covers would hand a dependent a
/// path to a file nothing produces — and, because the failure is in the
/// dependent's command rather than in the producer, it would be
/// reported against the wrong task. Refuse at load time instead.
fn provider_declaration_error(task : Task) -> String? {
  let exe = task.provides.executable
  if exe.length() == 0 {
    return None
  }
  if task.cmd.length() == 0 {
    return Some(
      "task `\{task.name}` declares `provides.executable` but has no `cmd`, so it produces nothing",
    )
  }
  for pattern in task.outputs {
    if glob_match(pattern, exe) {
      return None
    }
  }
  Some(
    "task `\{task.name}` declares `provides.executable = \"\{exe}\"`, which none of its `outputs` produce",
  )
}
