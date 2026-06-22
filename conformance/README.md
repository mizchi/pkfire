# pkf conformance harness

Differential contract tests: the Go `pkf` is the oracle, the MoonBit
`pkf` is the candidate. Scenarios are typed in `Conformance.pkl` and
listed in `scenarios.pkl`. Committed goldens under `golden/` are the
frozen contract.

## Run

    go build -o /tmp/pkf-go ./cmd/pkf        # from repo root
    cd conformance
    PKF_GO_BIN=/tmp/pkf-go go test ./...      # machinery + oracle self-check

## Candidate parity (writes LEDGER.md)

    cd pkf-mbt && moon build --target native --release && cd ..
    cd conformance
    PKF_MBT_BIN="$PWD/../pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe" \
      go test -run TestCandidateParity -v

## Regenerate goldens (after an intentional Go change)

    PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update

`PKF_CONFORMANCE_STRICT=1` makes candidate RED rows fail the build (use
once a command is expected to be at parity).
