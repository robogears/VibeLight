#!/bin/zsh
# Builds the two native C dependencies moonlight-common-c needs on iOS as
# .xcframeworks (device arm64 + simulator arm64):
#   - mbedcrypto   (AES-GCM etc. for the encrypted control/video/audio streams)
#   - opus         (audio decode in our AudioRenderer sink)
# enet + nanors + common-c itself are compiled straight from source in the app's
# MoonlightCore target — only these two third-party libs are prebuilt here.
#
# Output: ThirdParty/ios/{mbedcrypto,opus}.xcframework  (gitignored; rebuildable)
# Usage:  scripts/ios/build-deps.sh   (idempotent; skips a lib whose xcframework exists)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
OUT="$ROOT/ThirdParty/ios"
WORK="$ROOT/ThirdParty/ios/.build"
mkdir -p "$OUT" "$WORK"

IOS_MIN=17.0
MBEDTLS_TAG=v3.6.2
OPUS_TAG=v1.5.2

command -v cmake >/dev/null || { echo "cmake missing: brew install cmake"; exit 1; }

# ── Vendor the moonlight-common-c source the MoonlightCore target compiles ──
# Copied from the fork (kept out of git; this re-syncs it). Skips the 7 MB of
# unused SIMDe headers under nanors/deps/simde — nanors/obl doesn't include them.
FORK="$HOME/Documents/vibelight-moonlight-helper/moonlight-common-c/moonlight-common-c"
CORE="$ROOT/ThirdParty/moonlight-common-c"
if [[ -d "$FORK/src" ]]; then
  echo "── vendoring moonlight-common-c source ──"
  mkdir -p "$CORE/nanors/deps/obl"
  rsync -a --delete "$FORK/src/"  "$CORE/src/"
  rsync -a --delete "$FORK/enet/" "$CORE/enet/"
  cp "$FORK/nanors/rs.c" "$FORK/nanors/rs.h" "$CORE/nanors/"
  cp "$FORK/nanors/deps/obl/"*.h "$CORE/nanors/deps/obl/"
  cp "$FORK/LICENSE" "$CORE/" 2>/dev/null || true
else
  echo "⚠️  fork not at $FORK — MoonlightCore source not vendored (edit \$FORK)"
fi

# build_lib <name> <giturl> <tag> <cmake-extra-args...> -- <lib-relpath> <headers-src> <cmake-target>
build_lib() {
  local name="$1" url="$2" tag="$3"; shift 3
  local extra=(); while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done; shift
  local librel="$1" headers="$2" target="$3"
  if [[ -d "$OUT/$name.xcframework" ]]; then echo "✓ $name.xcframework exists — skipping"; return; fi

  local src="$WORK/$name"
  # --recurse-submodules: mbedTLS pulls its `framework` submodule its CMake needs.
  [[ -d "$src" ]] || git clone --depth 1 -b "$tag" --recurse-submodules "$url" "$src"

  local slices=()
  for sdk in iphoneos iphonesimulator; do
    local bdir="$WORK/$name-$sdk"
    echo "── building $name for $sdk ──"
    cmake -S "$src" -B "$bdir" -G "Unix Makefiles" \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_SYSROOT="$sdk" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
      "${extra[@]}" >/dev/null
    cmake --build "$bdir" --config Release --target "$target" -j"$(sysctl -n hw.ncpu)" >/dev/null
    slices+=(-library "$bdir/$librel" -headers "$src/$headers")
  done

  rm -rf "$OUT/$name.xcframework"
  xcodebuild -create-xcframework "${slices[@]}" -output "$OUT/$name.xcframework"
  echo "✅ $OUT/$name.xcframework"
}

# Only mbedcrypto is needed (AES/CTR-DRBG/MD for the encrypted streams); the TLS
# and x509 layers don't build cleanly for iOS and common-c never uses them.
build_lib mbedcrypto https://github.com/Mbed-TLS/mbedtls "$MBEDTLS_TAG" \
  -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -- library/libmbedcrypto.a include mbedcrypto

build_lib opus https://github.com/xiph/opus "$OPUS_TAG" \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
  -- libopus.a include opus

echo ""
echo "=== done ==="
ls -d "$OUT"/*.xcframework
