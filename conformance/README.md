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
    PKF_MBT_BIN="$PWD/../_build/native/release/build/src/cmd/pkf/pkf.exe" \
      moon run --target native --release src

Exit non-zero if any scenario is RED. This is the permanent contract
gate (the `.github/workflows/conformance.yml` job runs exactly this).

## Regenerate goldens (after an intentional behavior change)

    PKF_MBT_BIN="$PWD/../_build/native/release/build/src/cmd/pkf/pkf.exe" \
      moon run --target native --release src -- --update

Re-captures `golden/<id>/*` from the current `PKF_MBT_BIN` output.
Review the diff before committing — the goldens lock pkf's contracted
behavior, so a regeneration is an intentional contract change.
