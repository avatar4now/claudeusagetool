#!/bin/bash
# Builds Claude Usage Widget, checks the build, and installs it as the one copy in ~/Applications.
#
#   scripts/update-app.sh               run the tests, build, install, restart
#   scripts/update-app.sh --pull        get the latest version from GitHub first, then do the same
#   scripts/update-app.sh --skip-tests  skip the tests
#
# Running the app from Xcode creates a second copy in Xcode's build folder, which can confuse the widget.
# Run this script again afterwards to put the installed copy back in charge.
set -euo pipefail
cd "$(dirname "$0")/.."

project=ClaudeUsageWidget.xcodeproj
scheme=ClaudeUsageWidget
app_name=ClaudeUsageWidget.app
install_dir="$HOME/Applications"
installed="$install_dir/$app_name"
backup_dir="$HOME/Library/Application Support/ClaudeUsageWidget Backups"
widget_id=dev.huan.ClaudeUsageWidget.WidgetExtension
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

tmp_root="${TMPDIR:-/tmp}"
# The test build lives outside the project folder. When the project sits in an iCloud-synced folder such as
# Documents, iCloud tags files in a local build folder, and macOS then refuses to sign the test bundle.
spm_build="$HOME/Library/Caches/ClaudeUsageWidget/spm"

fail() { echo "✗ $*" >&2; exit 1; }

skip_tests=false
pull=false
for argument in "$@"; do
  case "$argument" in
    --skip-tests) skip_tests=true ;;
    --pull) pull=true ;;
    *) fail "Unknown option $argument. Use --pull or --skip-tests." ;;
  esac
done

if [[ "$pull" == true ]]; then
  echo "==> Getting the latest version"
  git pull --ff-only || fail "Couldn't update from GitHub. If you changed files here, commit or undo them, then try again."
fi

# Your Apple team signs the app. It lives in a file git ignores, so it's never published. On the first run the
# script reads it from the Apple Development certificate Xcode made when you added your Apple ID.
signing_local=Config/Signing.local.xcconfig
if [[ ! -f "$signing_local" ]]; then
  detected_team=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
  [[ -n "$detected_team" ]] || fail "No Apple Development certificate found. Open Xcode → Settings → Accounts, add your Apple ID, then click Manage Certificates and add an Apple Development certificate. Then run this again."
  printf '// Your Apple team for signing. This file stays on your Mac; git ignores it.\nDEVELOPMENT_TEAM = %s\n' "$detected_team" > "$signing_local"
  echo "==> Signing with your team $detected_team, saved in $signing_local"
fi
expected_team=$(awk -F'=' '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/{gsub(/[;" [:space:]]/, "", $2); print $2; exit}' "$signing_local")
[[ -n "$expected_team" ]] || fail "Put your Apple team ID in $signing_local, like: DEVELOPMENT_TEAM = ABCDE12345"

staging="$install_dir/.ClaudeUsageWidget-installing.app"
previous="$install_dir/.ClaudeUsageWidget-previous.app"
# If an earlier run was interrupted mid-swap, put the previous app back before doing anything else.
if [[ ! -d "$installed" && -d "$previous" ]]; then
  echo "==> Restoring the app left over from an interrupted install"
  mv "$previous" "$installed"
fi

if [[ "$skip_tests" != true ]]; then
  echo "==> Running tests"
  test_log=$(mktemp -t claude-usage-tests)
  if swift test --scratch-path "$spm_build" >"$test_log" 2>&1; then
    grep -E 'Executed [0-9]+ tests' "$test_log" | tail -1 | sed -E 's/^[[:space:]]+/    /'
  else
    grep -E 'error:|failed' "$test_log" | head -20 >&2 || true
    fail "Tests failed, so nothing was installed. Full log: $test_log"
  fi
fi

echo "==> Building (Release)"
# Record which code this build comes from, for Settings → About. If git can't answer, the build still goes ahead.
build_commit=$(git rev-parse --short HEAD 2>/dev/null || true)
build_branch=""
if [[ -n "$build_commit" ]]; then
  build_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  # A checked-out commit with no branch reports "HEAD". Leave the branch blank so it isn't mistaken for a branch name.
  if [[ "$build_branch" == "HEAD" ]]; then
    build_branch=""
  fi
  # Changes to tracked files count anywhere. Untracked files count only inside the folders Xcode builds,
  # so claude/ doesn't mark every build as modified but a new, not-yet-added Swift file does.
  dirty=$(git status --porcelain --untracked-files=no 2>/dev/null || true)
  dirty+=$(git status --porcelain --untracked-files=all -- Shared ClaudeUsageWidget ClaudeUsageWidgetExtension \
    "$project" 2>/dev/null || true)
  if [[ -n "$dirty" ]]; then
    build_commit="$build_commit-modified"
  fi
fi
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The GitHub repository this copy came from, as owner/name, so the app can say when a newer version is out.
# Only plain github.com addresses count, and any user name or token in the address is dropped.
source_repo=$(git remote get-url origin 2>/dev/null \
  | sed -E -e 's#^https://([^@/]*@)?github\.com/##' -e 's#^git@github\.com:##' -e 's#\.git$##' -e 's#/$##' || true)
[[ "$source_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || source_repo=""
if [[ -n "$build_commit" ]]; then
  echo "    Commit $build_commit on ${build_branch:-an unknown branch}"
else
  echo "    No git commit found; Settings will show no commit for this build."
fi
# Build outside ~/Documents: iCloud file attributes there can break code signing.
build_dir=$(mktemp -d -t claude-usage-build)
built="$build_dir/DerivedData/Build/Products/Release/$app_name"
appex="$built/Contents/PlugIns/ClaudeUsageWidgetExtension.appex"
# xcodebuild registers what it builds with LaunchServices. Unregister the temporary copy before deleting it,
# including when the script stops early, so macOS never keeps a widget pointing at a deleted folder.
cleanup() {
  if [[ -d "$built" ]]; then
    pluginkit -r "$appex" 2>/dev/null || true
    "$lsregister" -u "$built" 2>/dev/null || true
  fi
  rm -rf "$build_dir"
}
trap cleanup EXIT
build_log="$build_dir/build.log"
if ! xcodebuild -project "$project" -scheme "$scheme" -configuration Release -destination 'platform=macOS' \
     -derivedDataPath "$build_dir/DerivedData" \
     -clonedSourcePackagesDirPath "$HOME/Library/Caches/ClaudeUsageWidget/SourcePackages" \
     -onlyUsePackageVersionsFromResolvedFile \
     DEVELOPMENT_TEAM="$expected_team" \
     CUW_BUILD_COMMIT="$build_commit" CUW_BUILD_BRANCH="$build_branch" CUW_BUILD_DATE="$build_date" \
     CUW_SOURCE_REPO="$source_repo" \
     build >"$build_log" 2>&1; then
  grep -E 'error:' "$build_log" | head -20 >&2 || true
  saved_log="$tmp_root/claude-usage-build-failed.log"
  cp "$build_log" "$saved_log"
  fail "Build failed, so nothing was installed. Full log: $saved_log"
fi
[[ -d "$built" && -d "$appex" ]] || fail "Build finished, but the app or its widget is missing."

echo "==> Checking signatures"
codesign --verify --deep --strict "$built" || fail "The app's signature didn't verify."
codesign --verify --strict "$appex" || fail "The widget's signature didn't verify."
# Prints the signing team, or nothing for an unsigned or ad-hoc signed copy. Never fails the script by itself.
team_of() {
  local team
  team=$(codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}' || true)
  [[ "$team" == "not set" ]] && team=""
  echo "$team"
}
built_team=$(team_of "$built")
[[ "$built_team" == "$expected_team" ]] || fail "Built with team '$built_team', expected '$expected_team'. Keychain access would break."
[[ "$(team_of "$appex")" == "$expected_team" ]] || fail "The widget was signed by a different team than the app."
if [[ -d "$installed" ]]; then
  installed_team=$(team_of "$installed")
  if [[ -z "$installed_team" ]]; then
    echo "    The installed copy has no signing team; replacing it with the team-signed build."
  elif [[ "$installed_team" != "$built_team" ]]; then
    fail "The installed copy is signed by team '$installed_team'. Installing over it could lock the app out of its keychain items."
  fi
fi
version=$(plutil -extract CFBundleShortVersionString raw "$built/Contents/Info.plist")
build_number=$(plutil -extract CFBundleVersion raw "$built/Contents/Info.plist")
echo "    Team $built_team, version $version ($build_number)"

mkdir -p "$install_dir" "$backup_dir"
if [[ -d "$installed" ]]; then
  old_version=$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist" 2>/dev/null || echo unknown)
  backup="$backup_dir/ClaudeUsageWidget-$old_version-$(date +%Y%m%d-%H%M%S).zip"
  echo "==> Backing up the installed copy to $backup"
  # A zip, not a loose .app, so macOS doesn't register the backup's widget as another copy.
  ditto -c -k --keepParent "$installed" "$backup"
  ls -1t "$backup_dir"/ClaudeUsageWidget-*.zip 2>/dev/null | tail -n +4 | while read -r old; do rm -f "$old"; done
fi

echo "==> Installing to $installed"
rm -rf "$staging" "$previous"
ditto "$built" "$staging"
codesign --verify --deep --strict "$staging" || { rm -rf "$staging"; fail "The copied app didn't verify; the installed copy was left alone."; }

echo "==> Stopping the running app and widget"
was_running=false
pgrep -x ClaudeUsageWidget >/dev/null && was_running=true
pkill -x ClaudeUsageWidget 2>/dev/null || true
pkill -x ClaudeUsageWidgetExtension 2>/dev/null || true
for _ in {1..40}; do
  pgrep -x ClaudeUsageWidget >/dev/null || break
  sleep 0.25
done

if [[ -d "$installed" ]]; then mv "$installed" "$previous"; fi
if ! mv "$staging" "$installed"; then
  [[ -d "$previous" ]] && mv "$previous" "$installed"
  [[ "$was_running" == true ]] && open "$installed" || true
  fail "Couldn't move the new app into place; the previous copy was restored."
fi
rm -rf "$previous"

echo "==> Making the installed copy the only registered widget"
"$lsregister" -f "$installed" >/dev/null 2>&1 || true
pluginkit -a "$installed/Contents/PlugIns/ClaudeUsageWidgetExtension.appex" 2>/dev/null || true
# Other copies (Xcode builds, temporary build folders) stay registered until removed, and macOS may run their widget instead.
other_copies=$({
  pluginkit -m -A -D -v -i "$widget_id" 2>/dev/null |
    awk -F'\t' '$NF ~ /^[[:space:]]*\// {sub(/^[[:space:]]+/, "", $NF); print $NF}'
  "$lsregister" -dump 2>/dev/null | sed -nE 's/^path:[[:space:]]+(.*\/ClaudeUsageWidget\.app)( \(0x[0-9a-f]+\))?$/\1/p'
} | sort -u)
removed_other_copy=false
while IFS= read -r path; do
  [[ -z "$path" || "$path" == "$installed" || "$path" == "$installed"/* ]] && continue
  echo "    Unregistering ${path/#$HOME/~}"
  # This run's own temporary build was never used for the desktop widget, so it doesn't need a widget host restart.
  [[ "$path" == "$build_dir"/* || "$path" == "/private$build_dir"/* ]] || removed_other_copy=true
  case "$path" in
    *.appex) pluginkit -r "$path" 2>/dev/null || true ;;
    *.app)
      pluginkit -r "$path/Contents/PlugIns/ClaudeUsageWidgetExtension.appex" 2>/dev/null || true
      "$lsregister" -u "$path" 2>/dev/null || true ;;
  esac
done <<< "$other_copies"
# Stop any widget process that started from another copy while this ran; macOS relaunches it from the installed copy.
pkill -x ClaudeUsageWidgetExtension 2>/dev/null || true
if [[ "$removed_other_copy" == true ]]; then
  # The widget host caches which copy it launched and keeps retrying a removed one. Restarting it clears that;
  # macOS starts it again immediately, and every desktop widget redraws once.
  echo "    Restarting the widget host so it forgets the removed copies"
  killall chronod 2>/dev/null || true
  sleep 2
fi

echo "==> Opening the app"
open "$installed"
echo "==> Installed version $version ($build_number). Look for its item in the menu bar."
