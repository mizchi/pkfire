// MoonBit-native conformance runner — replaces the Go differential harness.
//
// Normal run: load scenarios from scenarios.pkl (embedded @pkl eval), run
// each against $PKF_MBT_BIN, Compare vs golden/<id>/*, print a PASS/RED
// ledger, and exit non-zero if any scenario is RED (the permanent gate,
// equivalent to Go's TestCandidateParity + PKF_CONFORMANCE_STRICT=1).
//
// Update run (PKF_CONFORMANCE_UPDATE=1 or argv "--update"): re-capture the
// goldens from the current $PKF_MBT_BIN output instead of diffing.

///|
struct LedgerRow {
  id : String
  command : String
  status : String
  detail : String
}

///|
async fn main {
  let args = @sys.get_cli_args()
  let mut update = @sys.get_env_var("PKF_CONFORMANCE_UPDATE") is Some("1")
  for i in 1..<args.length() {
    if args[i] == "--update" {
      update = true
    }
  }

  // cwd is expected to be the conformance/ directory (where scenarios.pkl and
  // golden/ live). repo_root is its parent (fixtures are repo-root-relative).
  let cwd = match @env.current_dir() {
    Some(d) => d
    None => {
      println("conformance: cannot determine cwd")
      @sys.exit(2)
      return
    }
  }
  let repo_root = parent_dir(cwd)
  let scenarios = match (try? load_scenarios("scenarios.pkl")) {
    Ok(s) => s
    Err(e) => {
      println("conformance: load scenarios: \{e}")
      @sys.exit(2)
      return
    }
  }
  let bin = match @sys.get_env_var("PKF_MBT_BIN") {
    Some(b) => b
    None => {
      println("conformance: PKF_MBT_BIN not set")
      @sys.exit(2)
      return
    }
  }
  if update {
    for s in scenarios {
      let res = run(bin, s, repo_root)
      capture_golden("golden", s, res)
      println("captured \{s.id}")
    }
    println("updated \{scenarios.length()} golden(s) from \{bin}")
    return
  }

  // Diff mode.
  let rows : Array[LedgerRow] = []
  let mut pass = 0
  for s in scenarios {
    let cmd = if s.argv.length() > 0 { s.argv[0] } else { "" }
    let row = match (try? load_golden("golden", s)) {
      Err(e) =>
        LedgerRow::{
          id: s.id,
          command: cmd,
          status: "RED",
          detail: "load golden: \{e}",
        }
      Ok(g) =>
        match (try? run(bin, s, repo_root)) {
          Err(e) =>
            LedgerRow::{
              id: s.id,
              command: cmd,
              status: "RED",
              detail: "run error: \{e}",
            }
          Ok(res) => {
            let d = compare(s, g, res)
            if d == "" {
              pass = pass + 1
              LedgerRow::{ id: s.id, command: cmd, status: "PASS", detail: "" }
            } else {
              LedgerRow::{ id: s.id, command: cmd, status: "RED", detail: d }
            }
          }
        }
    }
    rows.push(row)
  }
  print_ledger(rows, pass)
  if pass != rows.length() {
    @sys.exit(1)
  }
}

///|
fn print_ledger(rows : Array[LedgerRow], pass : Int) -> Unit {
  println("# Conformance Ledger (MoonBit runner)")
  println("")
  for r in rows {
    let mark = if r.status == "PASS" { "PASS" } else { "RED " }
    if r.detail == "" {
      println("\{mark}  \{r.id}  (\{r.command})")
    } else {
      println("\{mark}  \{r.id}  (\{r.command})  -- \{r.detail}")
    }
  }
  println("")
  println("\{pass}/\{rows.length()} passing")
}

///|
/// Parent directory of an absolute path (drop the last `/segment`).
fn parent_dir(path : String) -> String {
  let mut last = -1
  let chars = path.to_array()
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last = i
    }
  }
  if last <= 0 {
    "."
  } else {
    path.substring(start=0, end=last)
  }
}
