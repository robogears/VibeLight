#!/bin/zsh
# Builds a styled "drag to Applications" DMG installer for a built VibeLight.app.
# The DMG is for the FIRST manual install; the in-app self-updater still uses
# the .zip asset (in-place swap), so every release ships BOTH.
#
# Usage: make-dmg.sh /path/to/VibeLight.app /path/to/output/VibeLight-x.y.z-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: make-dmg.sh <VibeLight.app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <VibeLight.app> <output.dmg>}"
BG="scripts/dmg/dmg-background.png"

[[ -d "$APP" ]] || { echo "app not found: $APP"; exit 1; }
command -v create-dmg >/dev/null || { echo "create-dmg missing: brew install create-dmg"; exit 1; }

# create-dmg wants a source folder containing only what should appear.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/VibeLight.app"
xattr -cr "$STAGE/VibeLight.app"

rm -f "$OUT"
# Icon positions match the arrow in the background (both slots at Finder-y 185).
create-dmg \
  --volname "VibeLight" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "VibeLight.app" 165 185 \
  --hide-extension "VibeLight.app" \
  --app-drop-link 495 185 \
  --no-internet-enable \
  "$OUT" \
  "$STAGE" \
  || {
    # create-dmg needs a Finder session for the fancy layout; if that fails
    # (e.g. headless), fall back to a plain but functional drag DMG.
    echo "create-dmg failed; building a plain DMG with an Applications link"
    ln -sf /Applications "$STAGE/Applications"
    hdiutil create -volname "VibeLight" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
  }

echo "✅ DMG: $OUT"
