#!/usr/bin/env bash
#
# Bump every `pkfire@<old>` reference to `pkfire@<new>` and update
# pkl/PklProject's declared version. Run before tagging the release.
#
# Usage: scripts/bump-version.sh 0.2.0
set -euo pipefail

new="${1:?usage: $0 <new-version>}"
old=$(pkl eval -f json -x package.version pkl/PklProject | tr -d '"')

if [ "$old" = "$new" ]; then
  echo "version already pkfire@$new — nothing to bump"
  exit 0
fi

echo "bumping pkfire@${old} → pkfire@${new}"

perl -i -pe "s/version = \"${old}\"/version = \"${new}\"/" pkl/PklProject

# shellcheck disable=SC2046
perl -i -pe "s/pkfire\@${old}/pkfire\@${new}/g" $(
  git ls-files \
    'README.md' \
    'skills/**/*.md' \
    'skills/**/*.pkl' \
    'examples/basic/**/*.pkl' \
    'examples/node/**/*.pkl' \
    'examples/rust/**/*.pkl' \
    'examples/monorepo/**/*.pkl'
)

scripts/check-version-consistency.sh
echo
echo "Done. Review with \`git diff\`, commit, then tag with:"
echo "  git tag pkfire@${new} && git push origin main pkfire@${new}"
