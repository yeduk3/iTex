# tectonic-ffi — in-process LaTeX engine for iTex (Phase 3)

Thin C-FFI over the [Tectonic](https://github.com/tectonic-typesetting/tectonic) engine (MIT).
This is the **only** path that compiles LaTeX on **iOS**, where `Process` spawning is forbidden
(docs/02 C6, docs/03 §3.7). On macOS it's an optional warm in-process backend.

## Surface
Two C functions (`include/itex_tectonic.h`), hand-written — cbindgen unnecessary for a 2-fn ABI:
```c
unsigned char *itex_tectonic_compile(const unsigned char *input, size_t input_len, size_t *out_len);
void           itex_tectonic_free(unsigned char *ptr, size_t len);
```
Swift side: `Sources/TectonicBackend.swift` (a `CompileBackend`), gated by `ITEX_TECTONIC`.

## Build
```sh
# macOS host lib:
brew install harfbuzz freetype graphite2 icu4c libpng fontconfig pkg-config
./build-macos.sh                # → target/release/libitex_tectonic.a

# XCFramework (macOS + iOS device + sim) — needs rustup (NOT Homebrew rust):
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
./build-xcframework.sh          # → ItexTectonic.xcframework
```

## Verified (macOS, this repo)
`build-macos.sh` produces `libitex_tectonic.a` (~40MB) exporting `_itex_tectonic_compile` /
`_itex_tectonic_free`. An end-to-end FFI smoke test compiled a real document:
`itex_tectonic_compile(...) → PDF_BYTES=5110, header "%PDF-"`. When linking the static lib,
the app/target must also pull these system libs + frameworks (Xcode "Other Linker Flags"):
```
-lharfbuzz -licuuc -licui18n -licudata -lgraphite2 -lfreetype -lpng -lfontconfig -lz -lbz2 -liconv -lc++
-framework AppKit -framework CoreFoundation -framework CoreText -framework CoreGraphics
-framework Foundation -framework SystemConfiguration -framework Security
```
(with `-L` paths to the brew kegs). On iOS the deps are vendored into the XCFramework instead.

## Wire into the app
1. Add `ItexTectonic.xcframework` to the iTex target.
2. Add `tectonic-ffi/module` to `SWIFT_INCLUDE_PATHS` (exposes `import CItexTectonic`).
3. Add `ITEX_TECTONIC` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
4. iOS `LaTeXCompiler.buildPDF` then routes to `TectonicBackend` automatically.

## Known gaps / risks (carried from docs/05 §C)
- **Not hermetic:** `latex_to_pdf` fetches a TeXLive bundle + format over the network on first run
  (cached in `TECTONIC_CACHE_DIR`). For iOS, switch to the V2
  `tectonic::driver::ProcessingSessionBuilder` with a **shipped local bundle** + `format_cache_path`
  in the app cache dir (no network). TODO before iOS ship.
- **No published `aarch64-apple-ios` Tectonic build exists** — the iOS cross-compile is plausible
  (pure Rust + vendored C, no fork) but unproven under App Store entitlements. Spike required.
- **Binary size** ~200MB (Typetex's `libtectonic_ffi.a` reference) + bundled TeXLive subset.
- **SyncTeX:** pass `--synctex` via the V2 driver; the V1 helper used here returns no `.synctex.gz`.
- **This machine:** Homebrew `cargo`/`rustc` present but **no rustup** → iOS targets can't be added
  here; `build-macos.sh` (host lib) is the only buildable step in this environment.
- Prior art / packaging blueprint: [Typetex](https://github.com/jonasgunklach/Typetex)
  (Swift + libtectonic_ffi, macOS-only there).
