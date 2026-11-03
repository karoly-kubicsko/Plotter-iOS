#!/bin/bash
#
# Builds build/Plotter.app, a universal (Apple silicon + Intel) macOS application bundle:
#
#   Plotter.app/
#   └── Contents/
#       ├── Info.plist
#       ├── PkgInfo
#       ├── MacOS/Plotter            (executable)
#       ├── Resources/AppIcon.icns
#       └── _CodeSignature/          (ad-hoc signature)
#
# Requirements: macOS 26 with Xcode 26 or the matching Command Line Tools
# (install the latter with `xcode-select --install`).
#
# Usage: ./build.sh [--test] [--open]
#   --test   first compiles and runs the math-engine tests (Tests/main.swift)
#   --open   launches the app when the build has finished
#
# Set STRICT=1 to treat compiler warnings as errors (the CI build does this).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLIST="$ROOT/Resources/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

RUN_TESTS=0
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --test) RUN_TESTS=1 ;;
        --open) OPEN=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

FLAGS=(-swift-version 6 -O -sdk "$SDK")
if [[ "${STRICT:-0}" == "1" ]]; then
    FLAGS+=(-warnings-as-errors)
fi

rm -rf "$APP" "$BUILD/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"

if [[ "$RUN_TESTS" == "1" ]]; then
    echo "==> Testing the math engine"
    xcrun swiftc "${FLAGS[@]}" \
        -target "$(uname -m)-apple-macos$MIN_MACOS" \
        "$ROOT"/Sources/Math/*.swift "$ROOT"/Tests/main.swift \
        -o "$BUILD/obj/MathTests"
    "$BUILD/obj/MathTests"
fi

for arch in arm64 x86_64; do
    echo "==> Compiling $APP_NAME for $arch (macOS $MIN_MACOS+)"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library \
        -target "$arch-apple-macos$MIN_MACOS" \
        "$ROOT"/Sources/Math/*.swift "$ROOT"/Sources/App/*.swift \
        -o "$BUILD/obj/$APP_NAME-$arch"
done

echo "==> Assembling $APP"
lipo -create "$BUILD/obj/$APP_NAME-arm64" "$BUILD/obj/$APP_NAME-x86_64" \
    -output "$APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Make Finder and Launch Services pick up the (new) icon.
touch "$APP"

echo "==> Done: $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

if [[ "$OPEN" == "1" ]]; then
    open "$APP"
fi
