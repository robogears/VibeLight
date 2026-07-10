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
# Pin BOTH a human-readable tag AND the exact commit that tag pointed to when
# this script was written. A git tag is mutable — an attacker (or a compromised
# upstream) can force-push it to a hostile commit — so we clone by tag for speed
# but then REFUSE to build unless the checked-out commit matches the SHA below.
# To bump a dependency: change the tag, then regenerate the SHA with
#   git ls-remote https://github.com/<repo> refs/tags/<tag>^{}
# (the `^{}` peels the annotated tag to the commit `git rev-parse HEAD` reports).
MBEDTLS_TAG=v3.6.2
MBEDTLS_SHA=107ea89daaefb9867ea9121002fbbdf926780e98
OPUS_TAG=v1.5.2
OPUS_SHA=ddbe48383984d56acd9e1ab6a090c54ca6b735a6

command -v cmake >/dev/null || { echo "cmake missing: brew install cmake"; exit 1; }

# ── Vendor the moonlight-common-c source the MoonlightCore target compiles ──
# Copied from the fork (kept out of git; this re-syncs it). SIMDe IS required:
# nanors' obl/oblas_lite.c includes simde/x86/ssse3.h (portable SIMD shims).
FORK="$HOME/Documents/vibelight-moonlight-helper/moonlight-common-c/moonlight-common-c"
CORE="$ROOT/ThirdParty/moonlight-common-c"
if [[ -d "$FORK/src" ]]; then
  echo "── vendoring moonlight-common-c source ──"
  mkdir -p "$CORE/nanors/deps/obl"
  rsync -a --delete "$FORK/src/"  "$CORE/src/"
  rsync -a --delete "$FORK/enet/" "$CORE/enet/"
  cp "$FORK/nanors/rs.c" "$FORK/nanors/rs.h" "$CORE/nanors/"
  cp "$FORK/nanors/deps/obl/"*.h "$FORK/nanors/deps/obl/"*.c "$CORE/nanors/deps/obl/"
  rsync -a --delete "$FORK/nanors/deps/simde/" "$CORE/nanors/deps/simde/"
  cp "$FORK/LICENSE" "$CORE/" 2>/dev/null || true
else
  echo "⚠️  fork not at $FORK — MoonlightCore source not vendored (edit \$FORK)"
fi

# build_lib <name> <giturl> <tag> <sha> <cmake-extra-args...> -- <lib-relpath> <headers-src> <cmake-target>
build_lib() {
  local name="$1" url="$2" tag="$3" sha="$4"; shift 4
  local extra=(); while [[ "$1" != "--" ]]; do extra+=("$1"); shift; done; shift
  local librel="$1" headers="$2" target="$3"
  if [[ -d "$OUT/$name.xcframework" ]]; then echo "✓ $name.xcframework exists — skipping"; return; fi

  local src="$WORK/$name"
  # --recurse-submodules: mbedTLS pulls its `framework` submodule its CMake needs.
  [[ -d "$src" ]] || git clone --depth 1 -b "$tag" --recurse-submodules "$url" "$src"
  # Supply-chain guard: verify the tag still points at the commit we pinned.
  local got; got="$(git -C "$src" rev-parse HEAD)"
  if [[ "$got" != "$sha" ]]; then
    echo "✖ $name: $tag resolved to $got but expected $sha." >&2
    echo "  The tag may have been moved. Delete $src, verify the new commit is" >&2
    echo "  legitimate, then update the *_SHA pin at the top of this script." >&2
    exit 1
  fi

  local slices=()
  for sdk in iphoneos iphonesimulator; do
    local bdir="$WORK/$name-$sdk"
    # Device is arm64-only; the simulator slice must be universal (an Intel Mac
    # builds/runs the sim as x86_64, Apple Silicon as arm64).
    local archs="arm64"; [[ "$sdk" == "iphonesimulator" ]] && archs="arm64;x86_64"
    echo "── building $name for $sdk ($archs) ──"
    cmake -S "$src" -B "$bdir" -G "Unix Makefiles" \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_ARCHITECTURES="$archs" \
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
build_lib mbedcrypto https://github.com/Mbed-TLS/mbedtls "$MBEDTLS_TAG" "$MBEDTLS_SHA" \
  -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -- library/libmbedcrypto.a include mbedcrypto

build_lib opus https://github.com/xiph/opus "$OPUS_TAG" "$OPUS_SHA" \
  -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF \
  -- libopus.a include opus

echo ""
echo "=== done ==="
ls -d "$OUT"/*.xcframework
