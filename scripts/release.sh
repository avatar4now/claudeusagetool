#!/bin/bash
# Publishes the version in the Xcode project as a GitHub release, so everyone's copy of the app shows
# "Version X is available" within a day.
#
#   scripts/release.sh
#
# Needs the GitHub CLI (brew install gh, then gh auth login), and a clean main branch that's already pushed.
# The release holds source code only. Don't attach a built app: its signature includes your Apple ID email.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "✗ $*" >&2; exit 1; }

command -v gh >/dev/null || fail "Install the GitHub CLI first: brew install gh, then gh auth login."
version=$(awk -F' = ' '/MARKETING_VERSION = /{gsub(/[;" ]/, "", $2); print $2; exit}' ClaudeUsageWidget.xcodeproj/project.pbxproj)
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail "Couldn't read the version from the Xcode project."
tag="v$version"

branch=$(git rev-parse --abbrev-ref HEAD)
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "Commit or undo your changes first."
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$branch" 2>/dev/null || true)" ]] \
  || fail "Push $branch to GitHub first, with: git push"
if gh release view "$tag" >/dev/null 2>&1; then
  fail "$tag is already released. Raise MARKETING_VERSION in the Xcode project for a new release."
fi

gh release create "$tag" --target "$(git rev-parse HEAD)" --title "$version" --generate-notes
echo "==> Released $tag. Everyone's app will show the update within a day."
