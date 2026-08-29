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
  let args = @env.args()
  let mut update = @env.get_env_var("PKF_CONFORMANCE_UPDATE") is Some("1")
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
  let scenarios = load_scenarios("scenarios.pkl") catch {
    e => {
      println("conformance: load scenarios: \{e}")
      @sys.exit(2)
      return
    }
  }
  let bin = match @env.get_env_var("PKF_MBT_BIN") {
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
    let row = try load_golden("golden", s) catch {
      e =>
        LedgerRow::{
          id: s.id,
          command: cmd,
          status: "RED",
          detail: "load golden: \{e}",
        }
    } noraise {
      g =>
        try {
          let res = run(bin, s, repo_root)
          let d = compare(s, g, res)
          if d == "" {
            pass = pass + 1
            LedgerRow::{ id: s.id, command: cmd, status: "PASS", detail: "" }
          } else {
            LedgerRow::{ id: s.id, command: cmd, status: "RED", detail: d }
          }
        } catch {
          e =>
            LedgerRow::{
              id: s.id,
              command: cmd,
              status: "RED",
              detail: "run error: \{e}",
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
    path[0:last].to_owned()
  }
}
