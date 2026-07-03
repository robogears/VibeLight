#!/bin/zsh
# Builds VibeLight (Release) and installs it to /Applications so it's
# launchable from Spotlight, the Dock, or Launchpad like any other app.
# Re-run after code changes to update the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

xcodegen generate
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Release build | grep -E 'error|BUILD' || true

APP="$(xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/VibeLight.app"
[[ -d "$APP" ]] || { echo "Build product not found at $APP"; exit 1; }

DEST="/Applications/VibeLight.app"
if ! rm -rf "$DEST" 2>/dev/null || ! ditto "$APP" "$DEST" 2>/dev/null; then
    DEST="$HOME/Applications/VibeLight.app"   # fallback: no admin rights
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
fi
echo "✅ Installed: $DEST"
