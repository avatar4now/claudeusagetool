#!/bin/bash
# Publishes the version in the Xcode project as a GitHub release, so everyone's copy of the app shows
# "Version X is available" within a day.
#
#   scripts/release.sh               notes written by GitHub from the commits
#   scripts/release.sh notes.md      your own notes, from a Markdown file
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

# The repository this clone pushes to, as owner/name.
repo=$(git remote get-url origin | sed -E -e 's#^https://([^@/]*@)?github\.com/##' -e 's#^git@github\.com:##' -e 's#\.git$##' -e 's#/$##')
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "The origin remote isn't a GitHub repository."

# Created through the API directly; "gh release create" can fail here with a misleading permissions message.
if [[ -n "${1:-}" ]]; then
  [[ -f "$1" ]] || fail "Couldn't find the notes file $1."
  notes=(-F "body=@$1")
else
  notes=(-F generate_release_notes=true)
fi
url=$(gh api "repos/$repo/releases" -X POST -f tag_name="$tag" -f target_commitish="$(git rev-parse HEAD)" \
  -f name="$version" "${notes[@]}" --jq .html_url) || fail "GitHub didn't create the release."
echo "==> Released $tag: $url"
echo "    Everyone's app will show the update within a day."
