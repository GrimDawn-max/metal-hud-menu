#!/bin/zsh
# Builds the universal (arm64 + x86_64/Rosetta) stats library and copies the launch wrapper.
# StateReporting is resolved at runtime, not linked, so this builds on SDKs that
# predate it (Xcode 26) while still using it when running on macOS 27.
# Usage: NativeHUD/build.sh <output-dir>   (Xcode passes the app's Resources folder)
set -euo pipefail
src=${0:A:h}
out=${1:-$src/build}
tmp=${TEMP_DIR:-${TMPDIR:-/tmp}}
mkdir -p "$out"
for a in arm64 x86_64; do
  xcrun --sdk macosx clang++ -arch $a -mmacosx-version-min=26.0 -std=c++17 -O2 -fobjc-arc -dynamiclib \
    -install_name @rpath/libMHUDStats.dylib -framework Foundation -framework IOKit \
    "$src/mhud_stats.mm" -o "$tmp/libMHUDStats.$a.dylib"
done
xcrun lipo -create "$tmp/libMHUDStats.arm64.dylib" "$tmp/libMHUDStats.x86_64.dylib" -output "$out/libMHUDStats.dylib"
rm -f "$tmp"/libMHUDStats.{arm64,x86_64}.dylib
codesign --force --sign - "$out/libMHUDStats.dylib"
cp "$src/mhud-run" "$out/mhud-run"
chmod +x "$out/mhud-run"
