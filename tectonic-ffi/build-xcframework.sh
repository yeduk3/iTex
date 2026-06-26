#!/usr/bin/env bash
# Build an XCFramework for the iTex app (macOS + iOS device + iOS simulator) — docs/05 Phase 3a.
#
# PREREQS (the gap on this machine: Homebrew rust has no rustup; install via rustup to add targets):
#   rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
#   brew install harfbuzz freetype graphite2 icu4c libpng fontconfig pkg-config
set -euo pipefail
cd "$(dirname "$0")"

TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
for t in "${TARGETS[@]}"; do
  echo "== building $t =="
  cargo build --release --target "$t"
done

rm -rf ItexTectonic.xcframework
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libitex_tectonic.a       -headers include \
  -library target/aarch64-apple-ios-sim/release/libitex_tectonic.a   -headers include \
  -library target/aarch64-apple-darwin/release/libitex_tectonic.a    -headers include \
  -output ItexTectonic.xcframework

echo "OK → ItexTectonic.xcframework"
echo "Then: add it to the iTex target, add module/ to SWIFT_INCLUDE_PATHS,"
echo "and add ITEX_TECTONIC to SWIFT_ACTIVE_COMPILATION_CONDITIONS."
