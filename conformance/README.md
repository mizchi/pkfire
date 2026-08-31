# pkf conformance harness

Contract tests for the MoonBit `pkf`: the committed goldens under
`golden/` are the frozen ground truth, and the binary must reproduce
them exactly. Scenarios are typed in `Conformance.pkl` and listed in
`scenarios.pkl`. The runner is a MoonBit program under `src/` (it
evaluates `scenarios.pkl` through the embedded `@pkl` loader — the same
dependency `pkf` itself uses — so there is no separate toolchain).

## Run

    moon build src/cmd/pkf --target native --release
    cd conformance
    PKF_MBT_BIN="$PWD/../_build/native/release/build/mizchi/pkf/src/cmd/pkf/pkf.exe" \
      moon run --target native --release src

Exit non-zero if any scenario is RED. This is the permanent contract
gate (the `.github/workflows/conformance.yml` job runs exactly this).

## Regenerate goldens (after an intentional behavior change)

    PKF_MBT_BIN="$PWD/../_build/native/release/build/mizchi/pkf/src/cmd/pkf/pkf.exe" \
      moon run --target native --release src -- --update

Re-captures `golden/<id>/*` from the current `PKF_MBT_BIN` output.
Review the diff before committing — the goldens lock pkf's contracted
behavior, so a regeneration is an intentional contract change.

## What a golden is actually compared against

`compare` in `src/differ.mbt` applies only what the scenario's contract
asks for, in this order: `exit`, `json` (parsed, so formatting and key
order do not matter), `mustContain`, `fsDelta` / `fsDeleted`,
`mustContainStderr`, `stdoutEmpty`, `stdoutNonEmpty`.

Nothing compares stdout or stderr byte for byte. A scenario whose
contract is `exit` plus `mustContain` therefore carries `stdout` and
`stderr` goldens that no assertion reads — they are a record of what the
binary printed, useful in a review diff and nowhere else. The capture
also writes `fsdelta` / `fsdeleted` for any run that produced one, even
when the scenario does not set `fsDelta`, because it mirrors Go's
`CaptureGolden`.

The practical consequence: goldens drift silently. Between 0.12.0 and
0.16.0 the committed `version/stdout` still said `0.12.0`, the `help`
text was three releases old and the JSON goldens were pretty-printed
while the binary had moved to compact output — and the harness stayed
green throughout, correctly, because none of that is contracted. Re-run
`--update` after any user-visible output change so the recorded output
stays worth reading.
