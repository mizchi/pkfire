#!/usr/bin/env bash
#
# Assert that every `pkfire@<ver>` reference in user-facing files
# matches the version declared in pkl/PklProject. Run from the repo
# root.
#
# Excluded by design:
#   - pkl/PklProject itself (the source of truth)
#   - examples/dogfood/        (tests against the in-tree schema via
#                              relative amends; carries no version)
#   - .github/                 (workflow-input examples, not real refs)
#   - cmd/pkf/                 (binary version is stamped at link time)
set -euo pipefail

declared=$(pkl eval -f json -x package.version pkl/PklProject | tr -d '"')
echo "declared schema version: pkfire@$declared"

# Examples are not checked here: they pin to whatever Pkfire version
# is actually published on pkg.pkl-lang.org (typically lagging by one
# release because bumping them only makes sense after a release tag
# has been pushed and the publish workflow has uploaded the zip).
# The README + skills/recipes track the in-flight `pkl/PklProject`
# version so they always match what new users would see.
files=$(git ls-files \
  'README.md' \
  'skills/**/*.md' \
  'skills/**/*.pkl')

bad=0
total=0
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  total=$((total + 1))
  if [[ "$hit" != *"pkfire@$declared"* ]]; then
    echo "::error::stale reference (expected pkfire@$declared): $hit"
    bad=1
  fi
done <<EOF
$(printf '%s\n' $files | xargs -I {} grep -HEon 'pkfire@[0-9]+\.[0-9]+\.[0-9]+' {} 2>/dev/null || true)
EOF

if [ "$bad" -eq 1 ]; then
  echo
  echo "Run scripts/bump-version.sh <new-ver> after bumping pkl/PklProject" \
       "to update every reference."
  exit 1
fi

echo "ok: $total reference(s) all pin pkfire@$declared"
