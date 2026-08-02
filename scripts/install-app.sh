#!/bin/zsh
# Builds VibeLight (Release) and installs it to /Applications so it's
# launchable from Spotlight, the Dock, or Launchpad like any other app.
# Re-run after code changes to update the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

xcodegen generate
# `| grep … || true` swallowed xcodebuild's exit status (a pipeline reports the
# LAST command's status, and `|| true` buried what was left) — so a failed build
# printed its errors and the script cheerfully installed the previous, stale
# binary as if it were the new one.
#
# Read zsh's $pipestatus on the line IMMEDIATELY after the pipeline: any command
# in between (even `:`) replaces it. grep legitimately exits 1 when it matches
# nothing, so only element 1 — xcodebuild's own status — decides.
set +e
xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Release build \
    | grep -E 'error|BUILD'
build_status=(${pipestatus[@]})
set -e
if [[ ${build_status[1]} -ne 0 ]]; then
    echo "Build FAILED (xcodebuild exit ${build_status[1]}) — not installing."
    echo "The copy already in /Applications is unchanged."
    exit 1
fi

APP="$(xcodebuild -project VibeLight.xcodeproj -scheme VibeLight -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/VibeLight.app"
[[ -d "$APP" ]] || { echo "Build product not found at $APP"; exit 1; }

DEST="/Applications/VibeLight.app"
if ! rm -rf "$DEST" 2>/dev/null || ! ditto "$APP" "$DEST" 2>/dev/null; then
    DEST="$HOME/Applications/VibeLight.app"   # fallback: no admin rights
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
fi

# Remove the build-product copies from DerivedData so Spotlight only ever
# shows the one real install (otherwise you get "VibeLight — Debug/Release"
# duplicates alongside the Applications one).
find "$HOME/Library/Developer/Xcode/DerivedData" -name 'VibeLight.app' -path '*Products*' \
    -exec rm -rf {} + 2>/dev/null || true

# Embed the chromeless streaming helper (skipped with a warning if the fork
# isn't built — VibeLight then falls back to the dev build or stock Moonlight).
if ! "$(dirname "$0")/embed-helper.sh" "$DEST"; then
    echo "⚠️  Helper not embedded — VibeLight will use the dev-build/stock fallback."
fi

echo "✅ Installed: $DEST"
