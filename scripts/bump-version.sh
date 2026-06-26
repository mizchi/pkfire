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

# Keep the MoonBit binary version in lockstep with the Pkl schema
# version. The pkf binary is a MoonBit program; its module version
# (moon.mod.json) and the `pkf_version()` constant both ship `${new}`.
# The release workflow additionally sed-injects the resolved tag
# version into pkf_version() at build time, but the source constant
# tracks the declared version so local / `moon install` builds report
# the right number too. The regexes are value-agnostic because the
# binary version (0.x.y) never matched the schema version anyway.
perl -i -pe "s/^(\s*\"version\":\s*)\"[^\"]*\"/\${1}\"${new}\"/" moon.mod.json
perl -i -pe "s/^  \"[0-9]+\.[0-9]+\.[0-9]+\"\$/  \"${new}\"/" src/cmd/pkf/main.mbt

# Examples are deliberately excluded: they amend the public Pkl
# package URL, which only resolves once a release tag has been
# pushed and the publish workflow has uploaded the package zip.
# Bumping them pre-release leaves `pkl eval examples/<x>/Taskfile.pkl`
# 404'ing until the new version is actually released. After the
# release ships, bump examples in a follow-up commit (see the
# "Cut a release" section in README.md).
#
# Two reference forms get swept in lockstep:
#   - `pkfire@<ver>`         — Pkl package URI / release tag
#   - `mizchi/pkfire@v<ver>` — GitHub Action `uses:` pin (the v-tag
#                               that v-tags.yml publishes alongside
#                               each Pkl release)
# action.yml's own input.description references the action pin too.
files=$(git ls-files \
  'README.md' \
  'skills/**/*.md' \
  'skills/**/*.pkl' \
  'action.yml')

# shellcheck disable=SC2046
perl -i -pe "s/pkfire\@${old}/pkfire\@${new}/g; s|mizchi/pkfire\@v${old}|mizchi/pkfire\@v${new}|g" $files

scripts/check-version-consistency.sh
echo
echo "Done. Review with \`git diff\`, commit, then tag with:"
echo "  git tag pkfire@${new} && git push origin main pkfire@${new}"
