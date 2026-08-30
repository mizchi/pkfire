// Action IR — the canonical, hashable description of one executable
// action.
//
// Before this existed the action key was a hand-rolled hash over a
// hand-picked subset of `Task` fields, and the subset was wrong: the
// module-level `defaults.env` was handed to the command but never
// hashed, `inheritEnv` was invisible, the declared `outputs` were
// invisible, and so was the platform the action ran on. Two actions
// that produce different results shared a key, which is the one bug a
// content-addressed cache must not have.
//
// The fix is to stop hashing `Task` and start hashing a descriptor:
// every value that reaches the spawned process, and every value that
// decides what the process is expected to leave behind, is a field of
// `ActionDescriptor`. The key is a SHA-256 over its canonical
// serialization. Adding a new field to the descriptor is therefore the
// only way to add a field to the key — you cannot forget to hash
// something you have not put in the IR, and you cannot put something in
// the IR without hashing it.
//
// This mirrors Bazel's split between an Action and its execution: the
// descriptor is what an ActionCache would be keyed on and what a remote
// executor would be handed. `ActionDescriptor` is deliberately free of
// `Task`, `Plan`, and the filesystem so a future analysis phase can
// lower one Task into several descriptors.

///|
/// Bump when the canonical serialization changes shape. Every existing
/// cache entry is invalidated by a bump, which is the intent: a stale
/// entry written under a different set of hashed fields is not a hit.
const ACTION_IR_VERSION : String = "pkfire-action-v2"

///|
/// One spawned process, fully described.
///
/// Field order here is the serialization order; see `canonical_form`.
struct ActionDescriptor {
  /// Short kind tag. Every action is a `SpawnAction` today; the field
  /// exists so lowering a Task into (say) a `WriteFileAction` later
  /// changes the key rather than colliding with it.
  mnemonic : String
  /// The interpreter that is exec'd (`task.shell`).
  executable : String
  /// Full argument vector handed to `executable`, including the shell
  /// flags, the command text, and any forwarded positional args.
  argv : Array[String]
  /// Effective environment overlay, sorted by key. This is the *merged*
  /// view — module defaults, then task env, then param values — not
  /// just the task's own map.
  env : Array[(String, String)]
  /// Whether the ambient process environment leaks into the command.
  /// A cacheable action with this set is not hermetic: the key cannot
  /// see what the command reads. Hashing the flag at least stops a
  /// hermetic and a non-hermetic action from sharing an entry.
  inherit_env : Bool
  /// Declared inputs as (path relative to the action root, hex digest).
  inputs : Array[(String, String)]
  /// Files this action reads that another action in the graph
  /// produces, as (repo-relative path, hex digest), sorted.
  ///
  /// Separate from `inputs` because their provenance differs and so
  /// does their root: these are results, not sources, and they are
  /// recorded relative to the repo rather than to this action's
  /// working directory. Without them a task that declares
  /// `deps { build }` and no matching `inputs` line has a key blind to
  /// everything `build` wrote, and stays hit while its input changes
  /// underneath it.
  consumed_artifacts : Array[(String, String)]
  /// Declared output patterns, sorted. Two actions that run the same
  /// command but declare different outputs produce different cache
  /// entries and must not share a key.
  outputs : Array[String]
  /// Action root, normalized and relative to the repo root ("." when
  /// the action runs at the root). Absolute only when the Taskfile
  /// declared an absolute `workdir`.
  working_directory : String
  /// `<os>/<arch>` of the machine the action is executed on.
  execution_platform : String
  /// Everything else that constrains execution: declared tool
  /// versions, cache policy salt, run profile. Sorted by key.
  execution_properties : Array[(String, String)]
}

///|
/// Append one length-prefixed field to the canonical form.
///
/// The encoding is `tag=<byte-length>:<value>\n`. The length prefix is
/// what makes the form injection-proof: without it a task named
/// `a\nenv:B=c` could forge a second field and collide with a genuinely
/// different action. With it, the reader (and therefore the hash) can
/// only interpret exactly `byte-length` bytes as the value.
fn canon_field(buf : @buffer.Buffer, tag : String, value : String) -> Unit {
  let bytes = @utf8.encode(value)
  for b in @utf8.encode(tag + "=" + bytes.length().to_string() + ":") {
    buf.write_byte(b)
  }
  for b in bytes {
    buf.write_byte(b)
  }
  buf.write_byte(b'\n')
}

///|
/// Deterministic byte serialization of the descriptor.
///
/// Two descriptors serialize identically if and only if every field is
/// equal, so hashing this is equivalent to hashing the descriptor.
/// Sequence fields emit their length first so a 2-element and a
/// 3-element list can never produce the same bytes.
fn canonical_form(a : ActionDescriptor) -> Bytes {
  let buf = @buffer.Buffer(size_hint=1024)
  canon_field(buf, "version", ACTION_IR_VERSION)
  canon_field(buf, "mnemonic", a.mnemonic)
  canon_field(buf, "executable", a.executable)
  canon_field(buf, "argv.len", a.argv.length().to_string())
  for i, arg in a.argv {
    canon_field(buf, "argv." + i.to_string(), arg)
  }
  canon_field(buf, "env.len", a.env.length().to_string())
  for pair in a.env {
    canon_field(buf, "env.key", pair.0)
    canon_field(buf, "env.value", pair.1)
  }
  canon_field(buf, "inheritEnv", a.inherit_env.to_string())
  canon_field(buf, "inputs.len", a.inputs.length().to_string())
  for pair in a.inputs {
    canon_field(buf, "input.path", pair.0)
    canon_field(buf, "input.digest", pair.1)
  }
  canon_field(
    buf, "artifacts.len", a.consumed_artifacts.length().to_string(),
  )
  for pair in a.consumed_artifacts {
    canon_field(buf, "artifact.path", pair.0)
    canon_field(buf, "artifact.digest", pair.1)
  }
  canon_field(buf, "outputs.len", a.outputs.length().to_string())
  for out in a.outputs {
    canon_field(buf, "output", out)
  }
  canon_field(buf, "workdir", a.working_directory)
  canon_field(buf, "platform", a.execution_platform)
  canon_field(buf, "execprops.len", a.execution_properties.length().to_string())
  for pair in a.execution_properties {
    canon_field(buf, "execprop.key", pair.0)
    canon_field(buf, "execprop.value", pair.1)
  }
  buf.to_bytes()
}

///|
/// The action key: SHA-256 over the canonical form, hex-encoded.
fn action_key_of(a : ActionDescriptor) -> String {
  hex_encode(@crypto.sha256(canonical_form(a)))
}

///|
/// Human-readable dump of the descriptor, one field per line. Backs
/// `pkf run --explain-cache`, which answers "why did this miss?" — the
/// answer is always "one of these lines differs from last time".
fn describe_action(a : ActionDescriptor) -> String {
  let sb = StringBuilder()
  sb.write_string("  mnemonic:   " + a.mnemonic + "\n")
  sb.write_string("  executable: " + a.executable + "\n")
  sb.write_string("  workdir:    " + a.working_directory + "\n")
  sb.write_string("  platform:   " + a.execution_platform + "\n")
  sb.write_string("  inheritEnv: " + a.inherit_env.to_string() + "\n")
  sb.write_string("  argv (\{a.argv.length()}):\n")
  for arg in a.argv {
    sb.write_string("    " + arg + "\n")
  }
  sb.write_string("  env (\{a.env.length()}):\n")
  for pair in a.env {
    sb.write_string("    " + pair.0 + "=" + pair.1 + "\n")
  }
  sb.write_string("  execution properties (\{a.execution_properties.length()}):\n")
  for pair in a.execution_properties {
    sb.write_string("    " + pair.0 + "=" + pair.1 + "\n")
  }
  sb.write_string("  outputs (\{a.outputs.length()}):\n")
  for out in a.outputs {
    sb.write_string("    " + out + "\n")
  }
  sb.write_string("  inputs (\{a.inputs.length()}):\n")
  for pair in a.inputs {
    sb.write_string("    " + pair.1 + "  " + pair.0 + "\n")
  }
  if a.consumed_artifacts.length() > 0 {
    sb.write_string(
      "  consumed artifacts (\{a.consumed_artifacts.length()}):\n",
    )
    for pair in a.consumed_artifacts {
      sb.write_string("    " + pair.1 + "  " + pair.0 + "\n")
    }
  }
  // Trailing newline trimmed: callers `println` this.
  let out = sb.to_string()
  if out.has_suffix("\n") {
    out[0:out.length() - 1].to_owned()
  } else {
    out
  }
}

///|
/// `<os>/<arch>` of the host, resolved at compile time by the C stub.
extern "C" fn exec_platform_ffi() -> Bytes = "mizchi_pkf_exec_platform"

///|
/// Process id of the running `pkf`.
extern "C" fn current_pid() -> Int = "mizchi_pkf_getpid"

///|
fn exec_platform() -> String {
  @utf8.decode_lossy(exec_platform_ffi())
}

///|
/// Normalize a task's declared `workdir` into the form the descriptor
/// records: repo-relative, no `./` prefix, no trailing slash, "." for
/// the repo root. Absolute workdirs pass through — they are already
/// machine-specific, and that is the Taskfile author's choice.
fn normalize_workdir(workdir : String?) -> String {
  let raw = match workdir {
    Some(w) => w
    None => "."
  }
  if raw.length() == 0 {
    return "."
  }
  let mut s = raw
  while s.has_prefix("./") {
    s = s[2:s.length()].to_owned()
  }
  while s.length() > 1 && s.has_suffix("/") {
    s = s[0:s.length() - 1].to_owned()
  }
  if s.length() == 0 {
    "."
  } else {
    s
  }
}

///|
/// Lower a `Task` into the single `SpawnAction` it describes today.
///
/// This is the whole of "analysis" in the current engine: one Task
/// becomes exactly one action. Keeping it as a named function with a
/// Task-shaped input and a descriptor-shaped output is the seam a real
/// rule/provider analysis phase plugs into later — everything
/// downstream (keying, caching, execution) already speaks descriptor,
/// not Task.
fn lower_task_to_action(
  plan : Plan,
  task : Task,
  input_hashes : Array[(String, String)],
  params : Map[String, String],
  positionals : Array[String],
  profile : String,
  consumed_artifacts~ : Array[(String, String)] = [],
) -> ActionDescriptor {
  // argv: exactly what run_task hands to the shell, so the key sees the
  // real command line rather than a reconstruction of it.
  let argv : Array[String] = []
  for flag in task.shell_flags {
    argv.push(flag)
  }
  argv.push(task.cmd)
  if task.accepts_args && positionals.length() > 0 {
    argv.push(task.name)
    for pos in positionals {
      argv.push(pos)
    }
  }

  // env: the merged overlay the command actually receives — module
  // defaults first, then the task's own env, then param values as
  // uppercased vars. Precedence must match run_task's merge exactly or
  // the key describes an environment that never existed.
  let merged : Map[String, String] = Map([], capacity=8)
  for k, v in plan.default_env {
    merged[k] = v
  }
  for k, v in task.env {
    merged[k] = v
  }
  for pname, pvalue in params {
    merged[upcase(pname)] = pvalue
  }
  let env : Array[(String, String)] = []
  for k in sorted_keys(merged) {
    env.push((k, merged.get(k).unwrap()))
  }

  // Execution properties: declared tool versions (self-reported cache
  // salt), the run profile, and the raw param values. Params appear
  // here as well as in `env` because a param that is not referenced by
  // the command still selects a different action.
  let props : Map[String, String] = Map([], capacity=8)
  for k, v in task.tools {
    props["tool." + k] = v
  }
  for k, v in params {
    props["param." + k] = v
  }
  if profile.length() > 0 {
    props["profile"] = profile
  }
  let execution_properties : Array[(String, String)] = []
  for k in sorted_keys(props) {
    execution_properties.push((k, props.get(k).unwrap()))
  }
  let outputs : Array[String] = []
  for o in task.outputs {
    outputs.push(o)
  }
  outputs.sort_by(fn(a, b) { lex_cmp(a, b) })
  ActionDescriptor::{
    mnemonic: "SpawnAction",
    executable: task.shell,
    argv,
    env,
    inherit_env: task.inherit_env,
    inputs: input_hashes,
    consumed_artifacts,
    outputs,
    working_directory: normalize_workdir(task.workdir),
    execution_platform: exec_platform(),
    execution_properties,
  }
}
