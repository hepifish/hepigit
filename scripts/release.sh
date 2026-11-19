#!/bin/zsh
# Publishes a new version: bumps VERSION, builds the DMG, tags, and creates a GitHub release.
# Every installed Hepigit sees it on its next update check.
# usage: ./scripts/release.sh 1.0.1 "What changed, one line per fix"
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="${1:?usage: release.sh <version> \"notes\"}"
NOTES="${2:-Bug fixes.}"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
echo "$NEW" > VERSION
VERSION="$NEW" ./scripts/dmg.sh
git commit -qam "Release $NEW"
git tag "v$NEW"
git push -q && git push -q origin "v$NEW"
gh release create "v$NEW" "dist/Hepigit-$NEW.dmg" --title "Hepigit $NEW" --notes "$NOTES"
echo "Released $NEW"
