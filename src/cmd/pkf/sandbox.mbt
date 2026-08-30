// The sandbox executor: running an action against only what it declared.
//
// `inputs` has always been a promise about what the command reads, and
// nothing checked it. A task that reads a file it never declared runs
// fine, caches fine, and then serves a stale hit the day that file
// changes — the failure surfaces as a wrong build, far from the
// undeclared read that caused it. `pkf trace` can observe the real read
// set and report the gap, but reporting is advisory: the next
// undeclared read lands the same way.
//
// A sandbox makes the promise structural. Before the command runs,
// pkfire builds a tree containing exactly the declared inputs and the
// outputs of the actions this one depends on, and runs the command
// there. A read of anything else finds nothing, so the action fails
// where the mistake is rather than where its consequence is.
//
// This is Bazel's symlink forest, and deliberately not its namespace
// sandbox. Inputs are symlinked rather than copied, so materializing a
// large input set costs almost nothing, and absolute paths still
// resolve — `/usr/bin/cc`, `$HOME/.cargo`, the toolchain generally.
// That is a real limit and it is the point: hermetic *toolchains* are a
// separate problem (execution platforms, #60 P1), and a sandbox that
// hid `/usr/bin` would make every task fail for a reason that has
// nothing to do with its `inputs`. What this catches is the mistake
// people actually make: reading a workspace file you forgot to
// declare.
//
// Outputs are collected back into the workspace afterwards, so a task
// that writes something it did not declare leaves it in the sandbox and
// the workspace never sees it. Those writes are reported rather than
// silently dropped: an undeclared output is usually a missing `outputs`
// line, not a scratch file.

///|
/// A materialized action directory, plus the working directory inside
/// it that the command should run in.
struct Sandbox {
  /// Absolute path of the sandbox root. Mirrors whichever of the repo
  /// root and the task root contains the other.
  root : String
  /// Absolute path inside `root` corresponding to the task's own root:
  /// the directory the command runs in.
  cwd : String
  /// Absolute path inside `root` corresponding to the repo root, which
  /// is what artifact paths are relative to.
  artifact_root : String
}

///|
/// Where sandboxes live. Under the cache root rather than the
/// workspace: a sandbox is scratch space, and putting it in the
/// workspace would put it inside somebody's `inputs { "**" }`.
fn sandbox_base() -> String {
  join_path(cache_root(), "sandbox")
}

///|
/// Create an empty sandbox for one action.
///
/// The name carries the pid and a counter rather than the action key:
/// two runs of the same action in different processes must not share a
/// directory, and neither must two actions in one process.
fn sandbox_create(repo_root : String, task_cwd : String) -> Sandbox? {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => repo_root
  }
  let absolute_repo = absolute_lexical_path(repo_root, cwd)
  let absolute_task = absolute_lexical_path(task_cwd, cwd)
  // The sandbox mirrors whichever root contains the other. A Taskfile
  // in a subdirectory with `workdir = "../.."` — which is how a
  // repository dogfoods its own runner — has a task root *above* the
  // Taskfile's directory, and rooting the sandbox at the latter would
  // leave nowhere to put the command's working directory.
  let (task_rel, repo_rel) = match
    path_relative_to(absolute_repo, absolute_task) {
    Some(rel) => (rel, "")
    None =>
      match path_relative_to(absolute_task, absolute_repo) {
        Some(rel) => ("", rel)
        // Neither contains the other: no single tree can hold both, so
        // the caller reports and runs unsandboxed rather than
        // pretending to a guarantee it is not providing.
        None => return None
      }
  }
  let root = join_path(
    sandbox_base(),
    current_pid().to_string() + "." + next_store_seq().to_string(),
  )
  rm_rf(root)
  mkdir_p(root)
  if !@fs.path_exists(root) {
    return None
  }
  let inner = if task_rel.length() == 0 {
    root
  } else {
    join_path(root, task_rel)
  }
  let artifacts = if repo_rel.length() == 0 {
    root
  } else {
    join_path(root, repo_rel)
  }
  mkdir_p(inner)
  mkdir_p(artifacts)
  Some(Sandbox::{ root, cwd: inner, artifact_root: artifacts })
}

///|
/// Link one workspace file into the sandbox at the same relative path.
///
/// Symlinked, not copied: an input set is routinely thousands of files
/// and copying them would cost more than the action. The consequence is
/// that a command which *writes* to a declared input writes through to
/// the workspace — which is what an unsandboxed run does too, and is a
/// bug in the task either way.
async fn sandbox_link(
  sandbox_root : String,
  rel : String,
  source : String,
) -> Bool {
  let dest = join_path(sandbox_root, rel)
  let parent = dirname(dest)
  if parent.length() > 0 {
    mkdir_p(parent)
  }
  if @fs.path_exists(dest) {
    return true
  }
  @xfs.symlink(target=source.view(), dest.view()) catch {
    _ => return false
  }
  true
}

///|
/// Populate a sandbox with the action's declared inputs and the
/// artifacts it consumes from its dependencies.
///
/// `inputs` are relative to the task root; `artifacts` are relative to
/// the repo root. Both are mirrored at those same relative positions,
/// so a command that resolves either kind of path finds it exactly
/// where it would have been.
async fn sandbox_materialize(
  box : Sandbox,
  repo_root : String,
  task_cwd : String,
  inputs : Array[String],
  artifacts : Array[String],
) -> Bool {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => repo_root
  }
  let absolute_repo = absolute_lexical_path(repo_root, cwd)
  let absolute_task = absolute_lexical_path(task_cwd, cwd)
  for rel in inputs {
    let source = absolute_lexical_path(rel, absolute_task)
    if !@fs.path_exists(source) {
      continue
    }
    if !sandbox_link(box.cwd, rel, source) {
      return false
    }
  }
  for rel in artifacts {
    let source = absolute_lexical_path(rel, absolute_repo)
    if !@fs.path_exists(source) {
      continue
    }
    if !sandbox_link(box.artifact_root, rel, source) {
      return false
    }
  }
  true
}

///|
/// Move the action's declared outputs from the sandbox back into the
/// workspace, and report what it wrote that it did not declare.
///
/// Returns the paths of files written but not declared, relative to the
/// sandbox root. Input symlinks are skipped: they were put there by
/// `sandbox_materialize`, not by the command.
async fn sandbox_collect(
  box : Sandbox,
  task_cwd : String,
  outputs : Array[String],
) -> Array[String] {
  let declared : Map[String, Bool] = Map([], capacity=16)
  for pattern in outputs {
    // A literal output may name a directory, and `expand_inputs` only
    // ever yields files — moving the directory whole keeps an empty
    // subdirectory the action created, and costs one rename instead of
    // one per file.
    let matches : Array[String] = if pattern.contains("*") ||
      pattern.contains("?") ||
      pattern.contains("[") ||
      pattern.contains("{") {
      expand_inputs(box.cwd, [pattern])
    } else if @fs.path_exists(join_path(box.cwd, pattern)) {
      [pattern]
    } else {
      []
    }
    for rel in matches {
      declared[rel] = true
      let from = join_path(box.cwd, rel)
      let to = join_path(task_cwd, rel)
      let parent = dirname(to)
      if parent.length() > 0 {
        mkdir_p(parent)
      }
      rm_rf(to)
      // Rename first: same filesystem in the common case, and it keeps
      // modes and large trees cheap. Copy is the fallback for a cache
      // directory on a different device from the workspace.
      let renamed = try {
        @xfs.rename(from.view(), to.view(), replace=true)
        true
      } catch {
        _ => false
      }
      if !renamed {
        copy_tree_into(from, to)
      }
    }
  }
  // Anything else the command left behind, excluding the links we made
  // and the directories they needed.
  let entries : Array[(String, TarKind)] = []
  walk_tree(box.cwd, "", entries)
  let undeclared : Array[String] = []
  for entry in entries {
    match entry.1 {
      TarFile => if !declared.contains(entry.0) { undeclared.push(entry.0) }
      _ => ()
    }
  }
  undeclared.sort()
  undeclared
}

///|
/// Recursive copy used when a rename across devices fails.
fn copy_tree_into(from : String, to : String) -> Unit {
  match path_kind(from) {
    Some(TarDir) => {
      mkdir_p(to)
      let names = @fs.read_dir(from) catch { _ => [] }
      for name in names {
        copy_tree_into(join_path(from, name), join_path(to, name))
      }
    }
    _ => {
      let bytes = @fs.read_file_to_bytes(from) catch { _ => Bytes::new(0) }
      @fs.write_bytes_to_file(to, bytes) catch { _ => () }
    }
  }
}

///|
/// Remove a sandbox. Best effort: a leftover directory under the cache
/// root costs disk, not correctness, and `pkf cache clear` reclaims it.
fn sandbox_destroy(box : Sandbox) -> Unit {
  rm_rf(box.root)
}
