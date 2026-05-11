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

# Enumerate examples directly: `git ls-files 'examples/basic/**/*.pkl'`
# does NOT match top-level `examples/basic/Taskfile.pkl` (git pathspec
# `**` matches one or more dirs, not zero). Each example has exactly one
# Taskfile.pkl, so listing them explicitly is both robust and short.
# shellcheck disable=SC2046
perl -i -pe "s/pkfire\@${old}/pkfire\@${new}/g" $(
  git ls-files \
    'README.md' \
    'skills/**/*.md' \
    'skills/**/*.pkl' \
    'examples/basic/Taskfile.pkl' \
    'examples/node/Taskfile.pkl' \
    'examples/rust/Taskfile.pkl' \
    'examples/monorepo/Taskfile.pkl'
)

scripts/check-version-consistency.sh
echo
echo "Done. Review with \`git diff\`, commit, then tag with:"
echo "  git tag pkfire@${new} && git push origin main pkfire@${new}"
