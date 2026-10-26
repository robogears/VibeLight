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

# Stage THEN swap. This used to `rm -rf` the existing install and only then
# attempt the copy, with both commands' stderr sent to /dev/null — so a failure
# halfway through left no app at all and printed nothing about why.
install_to() {
    local dest="$1"
    ditto "$APP" "$dest.new" || return 1
    rm -rf "$dest" || { rm -rf "$dest.new"; return 1; }
    mv "$dest.new" "$dest"
}
DEST="/Applications/VibeLight.app"
if ! install_to "$DEST"; then
    echo "⚠️  Could not install to /Applications — falling back to ~/Applications."
    DEST="$HOME/Applications/VibeLight.app"   # fallback: no admin rights
    mkdir -p "$HOME/Applications"
    install_to "$DEST" || { echo "Install failed."; exit 1; }
fi

# Remove the build-product copies from DerivedData so Spotlight only ever
# shows the one real install (otherwise you get "VibeLight — Debug/Release"
# duplicates alongside the Applications one).
# Scoped to macOS RELEASE products only: VibeLight-iOS also sets
# PRODUCT_NAME=VibeLight, so a name-only match happily deleted the iOS device
# and simulator builds too, forcing a full rebuild after every install.
find "$HOME/Library/Developer/Xcode/DerivedData" -name 'VibeLight.app' \
    -path '*/Build/Products/Release/*' -not -path '*iphone*' \
    -exec rm -rf {} + 2>/dev/null || true

# Embed the chromeless streaming helper (skipped with a warning if the fork
# isn't built — VibeLight then uses the fork dev build; there is no
# stock-Moonlight fallback, so a missing helper is a clear error at stream time).
if ! "$(dirname "$0")/embed-helper.sh" "$DEST"; then
    # (audit QUA-install-stock-fallback-message: this used to promise a "stock
    # fallback" that was removed on purpose.)
    echo "⚠️  Helper not embedded — this copy can stream only on this Mac, and only while the"
    echo "   helper dev build exists in ~/Developer/vibelight-moonlight-helper. There is no"
    echo "   stock-Moonlight fallback. To fix: build the helper (see CLAUDE.md), then run this again."
fi

echo "✅ Installed: $DEST"
