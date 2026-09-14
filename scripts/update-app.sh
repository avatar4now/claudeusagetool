#!/bin/bash
# Rebuilds Claude Usage Widget and restarts it, so the newest code is what runs on your Mac.
#
#   scripts/update-app.sh               run the tests, build, restart
#   scripts/update-app.sh --skip-tests  build and restart only
set -euo pipefail
cd "$(dirname "$0")/.."

project=ClaudeUsageWidget.xcodeproj
scheme=ClaudeUsageWidget
destination='platform=macOS'

if [[ "${1:-}" != "--skip-tests" ]]; then
  echo "==> Running tests"
  test_log=$(mktemp -t claude-usage-tests)
  if swift test >"$test_log" 2>&1; then
    grep -E 'Executed [0-9]+ tests' "$test_log" | tail -1 | sed -E 's/^[[:space:]]+/    /'
  else
    grep -E 'error:|failed' "$test_log" | head -20 >&2 || true
    echo "Tests failed, so the app was not rebuilt. Full log: $test_log" >&2
    exit 1
  fi
fi

echo "==> Building"
log=$(mktemp -t claude-usage-build)
if ! xcodebuild -project "$project" -scheme "$scheme" -configuration Debug -destination "$destination" build >"$log" 2>&1; then
  grep -E 'error:' "$log" | head -20 >&2 || true
  echo "Build failed. Full log: $log" >&2
  exit 1
fi

products=$(xcodebuild -project "$project" -scheme "$scheme" -configuration Debug -destination "$destination" \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}')
app="$products/ClaudeUsageWidget.app"
if [[ ! -d "$app" ]]; then
  echo "Build finished, but the app wasn't found at $app" >&2
  exit 1
fi

echo "==> Restarting the app and its widget"
# Quit the old app, and stop the widget's background process so macOS starts the new one.
pkill -x ClaudeUsageWidget 2>/dev/null || true
pkill -x ClaudeUsageWidgetExtension 2>/dev/null || true
for _ in {1..40}; do
  pgrep -x ClaudeUsageWidget >/dev/null || break
  sleep 0.25
done
open "$app"

version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")
echo "==> Now running version $version ($build). Look for the gauge icon in your menu bar."
