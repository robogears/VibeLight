#!/bin/zsh
# Embeds the chromeless streaming helper (our moonlight-qt fork) inside
# VibeLight.app as Contents/Helpers/StreamHelper.app.
#
# The dev build of the fork links Qt out of /opt/homebrew — fine on this Mac,
# broken anywhere else. macdeployqt folds Qt frameworks + QML runtime into the
# bundle and fixes rpaths, making it relocatable. We deploy a COPY so the fork
# repo keeps its fast un-deployed dev build.
#
# Usage: embed-helper.sh /Applications/VibeLight.app
set -euo pipefail

APP="${1:?usage: embed-helper.sh /path/to/VibeLight.app}"
FORK="$HOME/Documents/vibelight-moonlight-helper"
SRC="$FORK/app/Moonlight.app"

[[ -d "$APP" ]] || { echo "VibeLight bundle not found: $APP"; exit 1; }
[[ -x "$SRC/Contents/MacOS/Moonlight" ]] || {
    echo "Helper not built. In $FORK run:"
    echo '  export PATH="$(brew --prefix qt)/bin:$PATH" && qmake moonlight-qt.pro && make release'
    exit 1
}
command -v "$(brew --prefix qt)/bin/macdeployqt" >/dev/null || { echo "macdeployqt missing: brew install qt"; exit 1; }

STAGE="$(mktemp -d)/StreamHelper.app"
trap 'rm -rf "${STAGE%/*}"' EXIT
ditto "$SRC" "$STAGE"

# Fold Qt + QML runtime into the bundle (idempotent on an already-deployed
# copy, but we always start from the clean dev build anyway).
MACDEPLOY_LOG="$(mktemp)"
if ! "$(brew --prefix qt)/bin/macdeployqt" "$STAGE" -qmldir="$FORK/app/gui" > "$MACDEPLOY_LOG" 2>&1; then
    echo "macdeployqt failed:"; grep -iE 'error' "$MACDEPLOY_LOG" | head -8
    exit 1
fi

# Strip extended attributes (Finder info/resource forks) — codesign hard-fails
# on this "detritus" and macdeployqt/ditto tend to leave some behind.
xattr -cr "$STAGE"

# Ad-hoc signing, inside-out: the helper (deep is acceptable for ad-hoc local
# builds), then the outer app gets re-sealed after embedding. Real Developer
# ID + notarization slots in here later without structural change.
codesign --force --deep -s - "$STAGE"

mkdir -p "$APP/Contents/Helpers"
rm -rf "$APP/Contents/Helpers/StreamHelper.app"
ditto "$STAGE" "$APP/Contents/Helpers/StreamHelper.app"

xattr -cr "$APP" 2>/dev/null || true
codesign --force -s - "$APP"

echo "✅ Embedded: $APP/Contents/Helpers/StreamHelper.app"
