package conformance

import (
	"fmt"
	"strings"
)

// LedgerRow is one scenario's parity status.
type LedgerRow struct {
	ID      string
	Command string
	Status  string // "PASS" or "RED"
	Detail  string
}

// RenderLedger produces the Markdown parity scoreboard.
func RenderLedger(rows []LedgerRow) string {
	var b strings.Builder
	passing := 0
	for _, r := range rows {
		if r.Status == "PASS" {
			passing++
		}
	}
	fmt.Fprintf(&b, "# pkf MoonBit parity ledger\n\n%d/%d passing\n\n", passing, len(rows))
	b.WriteString("| scenario | command | status | detail |\n")
	b.WriteString("|---|---|---|---|\n")
	for _, r := range rows {
		fmt.Fprintf(&b, "| %s | %s | %s | %s |\n", r.ID, r.Command, r.Status, r.Detail)
	}
	return b.String()
}
