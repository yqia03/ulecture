#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PDFIUM_ROOT="$APP_ROOT/Dependencies/pdfium-7999"
HELPER_OUT="${1:-$APP_ROOT/build/conversion}"
HELPER_SOURCE="${2:-$APP_ROOT/Sources/Conversion/PDFiumHelper.mm}"
mkdir -p "$HELPER_OUT"
test "$(shasum -a 256 "$PDFIUM_ROOT/pdfium-mac-arm64.tgz" | cut -d ' ' -f 1)" = "e214ee33f22b2204daa765a545aee1e425d88448e6154dac95c6a06206b7437f"
xcrun clang++ -std=c++17 -fobjc-arc -target arm64-apple-macos14.0 -O2 -ffile-prefix-map="$APP_ROOT=/ULecture/app" -I "$PDFIUM_ROOT/include" "$HELPER_SOURCE" -L "$PDFIUM_ROOT/lib" -lpdfium -framework Foundation -framework CoreGraphics -framework ImageIO -Wl,-rpath,@executable_path -o "$HELPER_OUT/ul-pdfium"
cp "$PDFIUM_ROOT/lib/libpdfium.dylib" "$HELPER_OUT/libpdfium.dylib"
install_name_tool -change ./libpdfium.dylib @executable_path/libpdfium.dylib "$HELPER_OUT/ul-pdfium"
install_name_tool -id @rpath/libpdfium.dylib "$HELPER_OUT/libpdfium.dylib"
codesign --force --sign - "$HELPER_OUT/libpdfium.dylib"
codesign --force --sign - "$HELPER_OUT/ul-pdfium"
