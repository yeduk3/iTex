#!/usr/bin/env bash
# Build the Tectonic FFI static lib for the host Mac (docs/05 Phase 3a).
#
# Cargo.toml pins tectonic via git tag (the crates.io 0.15.0 release is build-rotted) and enables
# `external-harfbuzz` so it links Homebrew harfbuzz instead of the buggy vendored submodule build.rs.
#
# Prereqs:
#   brew install harfbuzz graphite2 icu4c freetype libpng fontconfig pkg-config
set -euo pipefail
cd "$(dirname "$0")"

HB=$(brew --prefix harfbuzz); GR=$(brew --prefix graphite2); FT=$(brew --prefix freetype)
ICU=$(brew --prefix icu4c@78 2>/dev/null || brew --prefix icu4c); PNG=$(brew --prefix libpng); FC=$(brew --prefix fontconfig)

export PKG_CONFIG_PATH="$ICU/lib/pkgconfig:$HB/lib/pkgconfig:$GR/lib/pkgconfig:$FT/lib/pkgconfig:$PNG/lib/pkgconfig:$FC/lib/pkgconfig"
# xetex_layout's C++ does `#include <harfbuzz/hb.h>` → needs the include root on the search path.
export CPATH="$HB/include:$GR/include:/opt/homebrew/include"
export CFLAGS="-I$HB/include ${CFLAGS:-}"
# Homebrew icu4c@78 headers require C++17 (auto in template params); tectonic's cc defaults older.
export CXXFLAGS="-I$HB/include -std=c++17 ${CXXFLAGS:-}"

cargo build --release
echo "OK → target/release/libitex_tectonic.a"
echo "header → include/itex_tectonic.h ; module map → module/module.modulemap"
