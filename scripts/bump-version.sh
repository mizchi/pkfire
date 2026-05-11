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

# Examples are deliberately excluded: they amend the public Pkl
# package URL, which only resolves once a release tag has been
# pushed and the publish workflow has uploaded the package zip.
# Bumping them pre-release leaves `pkl eval examples/<x>/Taskfile.pkl`
# 404'ing until the new version is actually released. After the
# release ships, bump examples in a follow-up commit (see the
# "Cut a release" section in README.md).
# shellcheck disable=SC2046
perl -i -pe "s/pkfire\@${old}/pkfire\@${new}/g" $(
  git ls-files \
    'README.md' \
    'skills/**/*.md' \
    'skills/**/*.pkl'
)

scripts/check-version-consistency.sh
echo
echo "Done. Review with \`git diff\`, commit, then tag with:"
echo "  git tag pkfire@${new} && git push origin main pkfire@${new}"
