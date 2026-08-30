// Static watch-loop analysis.
//
// The glob solver below computes a concrete path accepted by two glob
// patterns, or proves that their path languages are disjoint. It models both
// path segments (`**`) and characters inside a segment (`*`, `?`, classes) as
// finite automata and searches their product. The resulting witness makes
// diagnostics actionable without enumerating the current filesystem.

///|
struct GlobCharTransition {
  next : Int
  kind : Int
  literal : Int
  pattern : String
  class_start : Int
  class_end : Int
  negate : Bool
}

///|
struct GlobCharProductState {
  left : Int
  right : Int
  text : String
}

///|
struct GlobPathProductState {
  left : Int
  right : Int
  path : String
}

///|
fn append_glob_char(text : String, ch : Int) -> String {
  let out = StringBuilder(size_hint=text.length() + 1)
  out.write_string(text)
  out.write_char(ch.unsafe_to_char())
  out.to_string()
}

///|
fn glob_char_transition(pattern : String, pos : Int) -> GlobCharTransition? {
  if pos >= pattern.length() {
    return None
  }
  let ch = pattern[pos]
  if ch == '*' {
    return Some(GlobCharTransition::{
      next: pos,
      kind: 0,
      literal: 0,
      pattern,
      class_start: 0,
      class_end: 0,
      negate: false,
    })
  }
  if ch == '?' {
    return Some(GlobCharTransition::{
      next: pos + 1,
      kind: 0,
      literal: 0,
      pattern,
      class_start: 0,
      class_end: 0,
      negate: false,
    })
  }
  if ch == '[' {
    let class_start = if pos + 1 < pattern.length() && pattern[pos + 1] == '!' {
      pos + 2
    } else {
      pos + 1
    }
    let mut class_end = -1
    for i = class_start; i < pattern.length(); i = i + 1 {
      if pattern[i] == ']' {
        class_end = i
        break
      }
    }
    if class_end >= 0 {
      return Some(GlobCharTransition::{
        next: class_end + 1,
        kind: 2,
        literal: 0,
        pattern,
        class_start,
        class_end,
        negate: class_start == pos + 2,
      })
    }
  }
  Some(GlobCharTransition::{
    next: pos + 1,
    kind: 1,
    literal: ch.to_int(),
    pattern,
    class_start: 0,
    class_end: 0,
    negate: false,
  })
}

///|
fn glob_char_transition_matches(t : GlobCharTransition, ch : Int) -> Bool {
  if ch == '/'.to_int() || ch == 0 {
    return false
  }
  if t.kind == 0 {
    return true
  }
  if t.kind == 1 {
    return t.literal == ch
  }
  let mut hit = false
  let mut i = t.class_start
  while i < t.class_end {
    if i + 2 < t.class_end && t.pattern[i + 1] == '-' {
      if ch >= t.pattern[i].to_int() && ch <= t.pattern[i + 2].to_int() {
        hit = true
      }
      i = i + 3
    } else {
      if ch == t.pattern[i].to_int() {
        hit = true
      }
      i = i + 1
    }
  }
  if t.negate {
    !hit
  } else {
    hit
  }
}

///|
fn glob_transition_witnesses(
  left : GlobCharTransition,
  right : GlobCharTransition,
) -> Array[Int] {
  let seen : Map[Int, Bool] = Map([], capacity=160)
  let candidates : Array[Int] = []
  fn add(code : Int) -> Unit {
    if !seen.contains(code) {
      seen[code] = true
      candidates.push(code)
    }
  }
  // Pattern characters contain every literal and every range boundary. If
  // two ranges overlap, at least one of their boundaries is in the overlap.
  fn add_neighborhood(code : Int) -> Unit {
    add(code)
    if code > 1 {
      add(code - 1)
    }
    if code < 0xffff {
      add(code + 1)
    }
  }
  // Prefer readable, cross-platform-safe witnesses when the language allows
  // one; range boundaries below complete the predicate partition.
  add('a'.to_int())
  add('0'.to_int())
  add('_'.to_int())
  add('-'.to_int())
  add('.'.to_int())
  for i in 0..<left.pattern.length() {
    add_neighborhood(left.pattern[i].to_int())
  }
  for i in 0..<right.pattern.length() {
    add_neighborhood(right.pattern[i].to_int())
  }
  add(1)
  add(0xffff)
  for code = 32; code <= 126; code = code + 1 {
    add(code)
  }
  let witnesses : Array[Int] = []
  for code in candidates {
    if glob_char_transition_matches(left, code) &&
      glob_char_transition_matches(right, code) {
      witnesses.push(code)
    }
  }
  witnesses
}

///|
fn glob_transition_witness(
  left : GlobCharTransition,
  right : GlobCharTransition,
) -> Int? {
  let witnesses = glob_transition_witnesses(left, right)
  if witnesses.length() == 0 {
    None
  } else {
    Some(witnesses[0])
  }
}

///|
fn glob_char_state_key(left : Int, right : Int, nonempty : Bool) -> String {
  left.to_string() +
  ":" +
  right.to_string() +
  ":" +
  (if nonempty { "1" } else { "0" })
}

///|
fn glob_segment_intersection_witness(left : String, right : String) -> String? {
  let queue : Array[GlobCharProductState] = [
    GlobCharProductState::{ left: 0, right: 0, text: "" },
  ]
  let seen : Map[String, Bool] = Map([], capacity=32)
  let mut cursor = 0
  while cursor < queue.length() {
    let state = queue[cursor]
    cursor = cursor + 1
    let key = glob_char_state_key(
      state.left,
      state.right,
      state.text.length() > 0,
    )
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    if state.left >= left.length() &&
      state.right >= right.length() &&
      state.text.length() > 0 {
      return Some(state.text)
    }
    // `*` has an epsilon transition to its following token.
    if state.left < left.length() && left[state.left] == '*' {
      queue.push(GlobCharProductState::{
        left: state.left + 1,
        right: state.right,
        text: state.text,
      })
    }
    if state.right < right.length() && right[state.right] == '*' {
      queue.push(GlobCharProductState::{
        left: state.left,
        right: state.right + 1,
        text: state.text,
      })
    }
    let left_transition = glob_char_transition(left, state.left)
    let right_transition = glob_char_transition(right, state.right)
    match (left_transition, right_transition) {
      (Some(lt), Some(rt)) =>
        match glob_transition_witness(lt, rt) {
          Some(code) =>
            queue.push(GlobCharProductState::{
              left: lt.next,
              right: rt.next,
              text: append_glob_char(state.text, code),
            })
          None => ()
        }
      _ => ()
    }
  }
  None
}

///|
fn glob_text_is_forbidden(
  text : String,
  forbidden : Array[String],
  forbid_tilde_suffix : Bool,
) -> Bool {
  if forbid_tilde_suffix && text.has_suffix("~") {
    return true
  }
  for word in forbidden {
    if text == word {
      return true
    }
  }
  false
}

///|
fn glob_forbidden_state_key(
  text : String,
  forbidden : Array[String],
  forbid_tilde_suffix : Bool,
) -> String {
  let key = StringBuilder(size_hint=forbidden.length() * 3 + 2)
  let mut has_prefix = false
  for i, word in forbidden {
    if word.has_prefix(text) {
      has_prefix = true
      key.write_string(i.to_string())
      key.write_char(',')
    }
  }
  if !has_prefix {
    key.write_char('x')
  }
  if forbid_tilde_suffix && text.has_suffix("~") {
    key.write_char('~')
  }
  key.to_string()
}

///|
fn glob_segment_intersection_witness_avoiding(
  left : String,
  right : String,
  forbidden : Array[String],
  forbid_tilde_suffix : Bool,
) -> String? {
  let queue : Array[GlobCharProductState] = [
    GlobCharProductState::{ left: 0, right: 0, text: "" },
  ]
  let seen : Map[String, Bool] = Map([], capacity=64)
  let mut cursor = 0
  while cursor < queue.length() {
    let state = queue[cursor]
    cursor = cursor + 1
    let key = state.left.to_string() +
      ":" +
      state.right.to_string() +
      ":" +
      glob_forbidden_state_key(state.text, forbidden, forbid_tilde_suffix)
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    if state.left >= left.length() &&
      state.right >= right.length() &&
      state.text.length() > 0 &&
      !glob_text_is_forbidden(state.text, forbidden, forbid_tilde_suffix) {
      return Some(state.text)
    }
    if state.left < left.length() && left[state.left] == '*' {
      queue.push(GlobCharProductState::{
        left: state.left + 1,
        right: state.right,
        text: state.text,
      })
    }
    if state.right < right.length() && right[state.right] == '*' {
      queue.push(GlobCharProductState::{
        left: state.left,
        right: state.right + 1,
        text: state.text,
      })
    }
    match
      (
        glob_char_transition(left, state.left),
        glob_char_transition(right, state.right),
      ) {
      (Some(left_transition), Some(right_transition)) =>
        for code in glob_transition_witnesses(left_transition, right_transition) {
          queue.push(GlobCharProductState::{
            left: left_transition.next,
            right: right_transition.next,
            text: append_glob_char(state.text, code),
          })
        }
      _ => ()
    }
  }
  None
}

///|
fn glob_path_state_key(left : Int, right : Int, nonempty : Bool) -> String {
  left.to_string() +
  ":" +
  right.to_string() +
  ":" +
  (if nonempty { "1" } else { "0" })
}

///|
fn append_glob_segment(path : String, segment : String) -> String {
  if path.length() == 0 {
    segment
  } else {
    path + "/" + segment
  }
}

///|
fn glob_expanded_intersection_witness(left : String, right : String) -> String? {
  let left_segments = left.split("/").collect()
  let right_segments = right.split("/").collect()
  let queue : Array[GlobPathProductState] = [
    GlobPathProductState::{ left: 0, right: 0, path: "" },
  ]
  let seen : Map[String, Bool] = Map([], capacity=32)
  let mut cursor = 0
  while cursor < queue.length() {
    let state = queue[cursor]
    cursor = cursor + 1
    let key = glob_path_state_key(
      state.left,
      state.right,
      state.path.length() > 0,
    )
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    if state.left >= left_segments.length() &&
      state.right >= right_segments.length() &&
      state.path.length() > 0 {
      return Some(state.path)
    }
    let left_doublestar = state.left < left_segments.length() &&
      left_segments[state.left] == "**"
    let right_doublestar = state.right < right_segments.length() &&
      right_segments[state.right] == "**"
    // `**` can consume zero complete path segments.
    if left_doublestar {
      queue.push(GlobPathProductState::{
        left: state.left + 1,
        right: state.right,
        path: state.path,
      })
    }
    if right_doublestar {
      queue.push(GlobPathProductState::{
        left: state.left,
        right: state.right + 1,
        path: state.path,
      })
    }
    if state.left >= left_segments.length() ||
      state.right >= right_segments.length() {
      continue
    }
    let left_pattern = if left_doublestar {
      "*"
    } else {
      left_segments[state.left].to_owned()
    }
    let right_pattern = if right_doublestar {
      "*"
    } else {
      right_segments[state.right].to_owned()
    }
    match glob_segment_intersection_witness(left_pattern, right_pattern) {
      Some(segment) =>
        queue.push(GlobPathProductState::{
          left: if left_doublestar {
            state.left
          } else {
            state.left + 1
          },
          right: if right_doublestar {
            state.right
          } else {
            state.right + 1
          },
          path: append_glob_segment(state.path, segment),
        })
      None => ()
    }
  }
  None
}

///|
fn glob_intersection_witness(left : String, right : String) -> String? {
  for expanded_left in brace_expand(left) {
    for expanded_right in brace_expand(right) {
      match glob_expanded_intersection_witness(expanded_left, expanded_right) {
        Some(path) => return Some(path)
        None => ()
      }
    }
  }
  None
}

///|
fn watch_safe_segment_witness(left : String, right : String) -> String? {
  let excluded_directories = [
    "_build", ".git", "node_modules", ".cache", "target",
  ]
  let excluded_terminal = [
    "_build", ".git", "node_modules", ".cache", "target", ".DS_Store",
  ]
  match
    glob_segment_intersection_witness_avoiding(
      left, right, excluded_terminal, true,
    ) {
    Some(segment) => Some(segment)
    None =>
      // A metadata-looking segment can still be visible when another path
      // segment follows it, so retain it as a fallback. Directory exclusions
      // remain forbidden at every depth.
      glob_segment_intersection_witness_avoiding(
        left, right, excluded_directories, false,
      )
  }
}

///|
fn watch_cycle_path_excluded(path : String) -> Bool {
  let anchored = if path.has_prefix("/") { path } else { "/" + path }
  fn has_segment(segment : String) -> Bool {
    anchored.contains("/" + segment + "/") || anchored.has_suffix("/" + segment)
  }
  has_segment("_build") ||
  has_segment(".git") ||
  has_segment("node_modules") ||
  has_segment(".cache") ||
  has_segment("target") ||
  anchored.has_suffix("/.DS_Store") ||
  anchored.has_suffix("~")
}

///|
fn glob_expanded_visible_intersection_witness(
  left : String,
  right : String,
) -> String? {
  let left_segments = left.split("/").collect()
  let right_segments = right.split("/").collect()
  let queue : Array[GlobPathProductState] = [
    GlobPathProductState::{ left: 0, right: 0, path: "" },
  ]
  let seen : Map[String, Bool] = Map([], capacity=32)
  let mut cursor = 0
  while cursor < queue.length() {
    let state = queue[cursor]
    cursor = cursor + 1
    let key = glob_path_state_key(
        state.left,
        state.right,
        state.path.length() > 0,
      ) +
      ":" +
      (if watch_cycle_path_excluded(state.path) { "x" } else { "v" })
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    if state.left >= left_segments.length() &&
      state.right >= right_segments.length() &&
      state.path.length() > 0 &&
      !watch_cycle_path_excluded(state.path) {
      return Some(state.path)
    }
    let left_doublestar = state.left < left_segments.length() &&
      left_segments[state.left] == "**"
    let right_doublestar = state.right < right_segments.length() &&
      right_segments[state.right] == "**"
    if left_doublestar {
      queue.push(GlobPathProductState::{
        left: state.left + 1,
        right: state.right,
        path: state.path,
      })
    }
    if right_doublestar {
      queue.push(GlobPathProductState::{
        left: state.left,
        right: state.right + 1,
        path: state.path,
      })
    }
    if state.left >= left_segments.length() ||
      state.right >= right_segments.length() {
      continue
    }
    let left_pattern = if left_doublestar {
      "*"
    } else {
      left_segments[state.left].to_owned()
    }
    let right_pattern = if right_doublestar {
      "*"
    } else {
      right_segments[state.right].to_owned()
    }
    match watch_safe_segment_witness(left_pattern, right_pattern) {
      Some(segment) =>
        queue.push(GlobPathProductState::{
          left: if left_doublestar {
            state.left
          } else {
            state.left + 1
          },
          right: if right_doublestar {
            state.right
          } else {
            state.right + 1
          },
          path: append_glob_segment(state.path, segment),
        })
      None => ()
    }
  }
  None
}

///|
fn watch_intersection_witness(left : String, right : String) -> String? {
  if glob_intersection_witness(left, right) is None {
    return None
  }
  for expanded_left in brace_expand(left) {
    for expanded_right in brace_expand(right) {
      match
        glob_expanded_visible_intersection_witness(
          expanded_left, expanded_right,
        ) {
        Some(path) => return Some(path)
        None => ()
      }
    }
  }
  None
}

///|
struct WatchTaskContract {
  name : String
  inputs : Array[String]
  outputs : Array[String]
  writes_cache : Bool
}

///|
struct WatchCycle {
  tasks : Array[String]
  kind : String
  producer : String
  consumer : String
  write_pattern : String
  input_pattern : String
  witness : String
}

///|
struct WatchEdge {
  producer : Int
  consumer : Int
  kind : String
  write_pattern : String
  input_pattern : String
  witness : String
}

///|
fn push_watch_edge_once(
  edges : Array[WatchEdge],
  candidate : WatchEdge,
) -> Unit {
  for edge in edges {
    if edge.producer == candidate.producer &&
      edge.consumer == candidate.consumer &&
      edge.kind == candidate.kind &&
      edge.write_pattern == candidate.write_pattern &&
      edge.input_pattern == candidate.input_pattern {
      return
    }
  }
  edges.push(candidate)
}

///|
fn watch_reachable(edges : Array[WatchEdge], start : Int, target : Int) -> Bool {
  let stack : Array[Int] = [start]
  let seen : Map[Int, Bool] = Map([], capacity=8)
  while stack.length() > 0 {
    let current = stack.pop().unwrap()
    if seen.contains(current) {
      continue
    }
    seen[current] = true
    for edge in edges {
      if edge.producer != current {
        continue
      }
      if edge.consumer == target {
        return true
      }
      if !seen.contains(edge.consumer) {
        stack.push(edge.consumer)
      }
    }
  }
  false
}

///|
fn find_watch_cycles(
  tasks : Array[WatchTaskContract],
  cache_pattern : String?,
) -> Array[WatchCycle] {
  let edges : Array[WatchEdge] = []
  for producer_index, producer in tasks {
    let write_patterns : Array[(String, String)] = []
    if producer.writes_cache {
      match cache_pattern {
        Some(pattern) => write_patterns.push(("cache", pattern))
        None => ()
      }
    }
    for pattern in producer.outputs {
      write_patterns.push(("output", pattern))
    }
    for write in write_patterns {
      for consumer_index, consumer in tasks {
        for input_pattern in consumer.inputs {
          match watch_intersection_witness(write.1, input_pattern) {
            Some(witness) =>
              push_watch_edge_once(edges, WatchEdge::{
                producer: producer_index,
                consumer: consumer_index,
                kind: write.0,
                write_pattern: write.1,
                input_pattern,
                witness,
              })
            None => ()
          }
        }
      }
    }
  }
  let cycles : Array[WatchCycle] = []
  // Preserve distinct self-loop causes: a task can watch both its declared
  // output and the configured local cache.
  for edge in edges {
    if edge.producer == edge.consumer {
      let name = tasks[edge.producer].name
      cycles.push(WatchCycle::{
        tasks: [name],
        kind: edge.kind,
        producer: name,
        consumer: name,
        write_pattern: edge.write_pattern,
        input_pattern: edge.input_pattern,
        witness: edge.witness,
      })
    }
  }
  // Every multi-node strongly connected component is one cross-task loop.
  let assigned : Map[Int, Bool] = Map([], capacity=tasks.length())
  for i in 0..<tasks.length() {
    if assigned.contains(i) {
      continue
    }
    let component : Array[Int] = [i]
    for j = i + 1; j < tasks.length(); j = j + 1 {
      if watch_reachable(edges, i, j) && watch_reachable(edges, j, i) {
        component.push(j)
      }
    }
    if component.length() <= 1 {
      continue
    }
    let names : Array[String] = []
    for index in component {
      assigned[index] = true
      names.push(tasks[index].name)
    }
    names.sort_by(fn(a, b) { lex_cmp(a, b) })
    let member_set : Map[Int, Bool] = Map([], capacity=component.length())
    for index in component {
      member_set[index] = true
    }
    for edge in edges {
      if edge.producer != edge.consumer &&
        member_set.contains(edge.producer) &&
        member_set.contains(edge.consumer) {
        cycles.push(WatchCycle::{
          tasks: names,
          kind: "cross-task",
          producer: tasks[edge.producer].name,
          consumer: tasks[edge.consumer].name,
          write_pattern: edge.write_pattern,
          input_pattern: edge.input_pattern,
          witness: edge.witness,
        })
        break
      }
    }
  }
  cycles
}

///|
fn repo_relative_watch_path(repo_root : String, event_path : String) -> String? {
  let root = lexical_normalize_path(repo_root)
  let normalized_event = lexical_normalize_path(event_path)
  if normalized_event == root {
    return Some("")
  }
  if !event_path.has_prefix("/") {
    let relative = normalized_event
    if relative == ".." || relative.has_prefix("../") {
      return None
    }
    return if relative == "." { Some("") } else { Some(relative) }
  }
  let prefix = if root == "/" { "/" } else { root + "/" }
  if normalized_event.has_prefix(prefix) {
    Some(normalized_event[prefix.length():].to_owned())
  } else {
    None
  }
}

///|
fn lexical_normalize_path(path : String) -> String {
  let absolute = path.has_prefix("/")
  let segments : Array[String] = []
  for view in path.split("/") {
    let segment = view.to_owned()
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." {
      if segments.length() > 0 && segments[segments.length() - 1] != ".." {
        ignore(segments.pop())
      } else if !absolute {
        segments.push(segment)
      }
    } else {
      segments.push(segment)
    }
  }
  let out = StringBuilder(size_hint=path.length())
  if absolute {
    out.write_char('/')
  }
  for i, segment in segments {
    if i > 0 {
      out.write_char('/')
    }
    out.write_string(segment)
  }
  let normalized = out.to_string()
  if normalized.length() == 0 {
    if absolute {
      "/"
    } else {
      "."
    }
  } else {
    normalized
  }
}

///|
fn absolute_lexical_path(path : String, cwd : String) -> String {
  if path.has_prefix("/") {
    lexical_normalize_path(path)
  } else {
    lexical_normalize_path(join_path(cwd, path))
  }
}

///|
fn path_relative_to(root : String, path : String) -> String? {
  let normalized_root = lexical_normalize_path(root)
  let normalized_path = lexical_normalize_path(path)
  repo_relative_watch_path(normalized_root, normalized_path)
}

///|
/// Re-root one of a task's declared patterns from its `workdir` to the
/// repo root. `None` when the pattern resolves outside the repo, which
/// nothing in the graph can match.
///
/// Every consumer of a task's patterns — the watcher, the cycle
/// analyzer, artifact matching — has to agree on this normalization or
/// two patterns that name the same file compare unequal.
fn repo_relative_pattern(
  repo_root : String,
  task : Task,
  pattern : String,
) -> String? {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => repo_root
  }
  let absolute_repo = absolute_lexical_path(repo_root, cwd)
  let task_root = match task.workdir {
    Some(workdir) => absolute_lexical_path(workdir, absolute_repo)
    None => absolute_repo
  }
  match path_relative_to(absolute_repo, absolute_lexical_path(pattern, task_root)) {
    Some(relative) => Some(if relative.length() == 0 { "**" } else { relative })
    None => None
  }
}

///|
fn task_watch_input_patterns(repo_root : String, task : Task) -> Array[String] {
  let patterns : Array[String] = []
  let seen : Map[String, Bool] = Map([], capacity=task.inputs.length())
  for input in task.inputs {
    match repo_relative_pattern(repo_root, task, input) {
      Some(pattern) =>
        if !seen.contains(pattern) {
          seen[pattern] = true
          patterns.push(pattern)
        }
      None => ()
    }
  }
  patterns
}

///|
fn task_watch_output_patterns(repo_root : String, task : Task) -> Array[String] {
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
  let seen : Map[String, Bool] = Map([], capacity=task.outputs.length())
  for output in task.outputs {
    let absolute_output = absolute_lexical_path(output, task_root)
    match path_relative_to(absolute_repo, absolute_output) {
      Some(relative) => {
        let region = if relative.length() == 0 {
          "**"
        } else if relative == "**" || relative.has_suffix("/**") {
          relative
        } else {
          relative + "/**"
        }
        if !seen.contains(region) {
          seen[region] = true
          patterns.push(region)
        }
      }
      _ => ()
    }
  }
  patterns
}

///|
fn watch_cache_pattern(repo_root : String) -> String? {
  let cwd = match @env.current_dir() {
    Some(dir) => dir
    None => repo_root
  }
  let absolute_repo = absolute_lexical_path(repo_root, cwd)
  let absolute_cache = absolute_lexical_path(cache_root(), cwd)
  match path_relative_to(absolute_repo, absolute_cache) {
    Some(relative) if relative.length() > 0 => {
      let pattern = relative + "/cas/**"
      if watch_cycle_path_excluded(pattern) {
        None
      } else {
        Some(pattern)
      }
    }
    Some(_) =>
      if watch_cycle_path_excluded("cas/**") {
        None
      } else {
        Some("cas/**")
      }
    None => None
  }
}

///|
fn watch_cycles_for_plan(
  plan : Plan,
  repo_root : String,
  scope : Map[String, Bool],
) -> Array[WatchCycle] {
  let contracts : Array[WatchTaskContract] = []
  for name in plan.task_order {
    if !scope.is_empty() && !scope.contains(name) {
      continue
    }
    let task = match plan.tasks.get(name) {
      Some(value) => value
      None => continue
    }
    if task.service {
      continue
    }
    contracts.push(WatchTaskContract::{
      name,
      inputs: task_watch_input_patterns(repo_root, task),
      outputs: task_watch_output_patterns(repo_root, task),
      writes_cache: task.cache && task.cmd.length() > 0,
    })
  }
  find_watch_cycles(contracts, watch_cache_pattern(repo_root))
}

///|
fn watch_cycle_lint_kind(cycle : WatchCycle) -> String {
  match cycle.kind {
    "cache" => "input-cache-watch-cycle"
    "output" => "input-output-watch-cycle"
    _ => "cross-task-watch-cycle"
  }
}

///|
fn watch_cycle_message(cycle : WatchCycle) -> String {
  if cycle.kind == "cache" {
    return "task \"\{cycle.producer}\" watches input \"\{cycle.input_pattern}\" which overlaps local cache writes \"\{cycle.write_pattern}\" (example: \"\{cycle.witness}\")"
  }
  if cycle.kind == "output" {
    return "task \"\{cycle.producer}\" watches input \"\{cycle.input_pattern}\" which overlaps its output \"\{cycle.write_pattern}\" (example: \"\{cycle.witness}\")"
  }
  "tasks " +
  join_with(cycle.tasks, " -> ") +
  " form a watch loop: \"\{cycle.producer}\" writes \"\{cycle.write_pattern}\", watched by \"\{cycle.consumer}\" as \"\{cycle.input_pattern}\" (example: \"\{cycle.witness}\")"
}

///|
fn watch_cycle_suggestion(cycle : WatchCycle) -> String {
  if cycle.kind == "cache" {
    "move PKFIRE_MBT_CACHE_DIR outside the watched repository, use an excluded .cache directory, or narrow the task inputs"
  } else if cycle.kind == "output" {
    "exclude generated outputs from the task inputs, or narrow the input/output glob patterns so they are disjoint"
  } else {
    "make at least one producer output disjoint from the next task's inputs to break the watch cycle"
  }
}
