#!/usr/bin/env bash
#
# Extract release notes for a given version from CHANGELOG.md.
# Usage: scripts/release-notes.sh <version>
#
# Prints everything between `## [<version>]` (exclusive) and the next
# top-level section header (`## [...]`) or EOF, whichever comes first.
# Used by .github/workflows/pkl-publish.yml to populate the GitHub
# release body from CHANGELOG.md so the user-facing announcement and
# the repo's source of truth never drift.
#
# Exits 0 with empty stdout when the version isn't found; callers can
# detect that and fall back to a default body.
set -euo pipefail
version="${1:?usage: $0 <version>}"
awk -v ver="$version" '
  $0 ~ "^## \\[" ver "\\]" { found=1; next }
  found && /^## \[/        { exit }
  found                    { print }
' CHANGELOG.md
