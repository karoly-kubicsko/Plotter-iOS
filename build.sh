#!/bin/bash
#
# Builds build/Plotter.app, an iOS Simulator application bundle, with swiftc only (no Xcode
# project):
#
#   Plotter.app/
#   ├── Info.plist
#   ├── Plotter              (executable, arm64 for the simulator on Apple silicon)
#   ├── Assets.car           (app icon, compiled by actool)
#   └── _CodeSignature/      (ad-hoc signature)
#
# Requirements: macOS 26 with Xcode 26 (the iOS 26 SDK; the command line tools alone
# do not include the iOS SDKs).
#
# Usage: ./build.sh [--test]
#   --test   first compiles and runs the math-engine tests (Tests/main.swift) on the Mac
#
# Set STRICT=1 to treat compiler warnings as errors. Set ARCH=x86_64 on an Intel Mac.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PLIST="$ROOT/Resources/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
MIN_IOS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST")"
ARCH="${ARCH:-arm64}"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

RUN_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --test) RUN_TESTS=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

FLAGS=(-swift-version 6 -O)
if [[ "${STRICT:-0}" == "1" ]]; then
    FLAGS+=(-warnings-as-errors)
fi

rm -rf "$BUILD"
mkdir -p "$APP" "$BUILD/obj" "$BUILD/Assets.xcassets/AppIcon.appiconset"

if [[ "$RUN_TESTS" == "1" ]]; then
    # The math engine uses only Foundation, so its tests run on the Mac itself.
    echo "==> Testing the math engine"
    xcrun --sdk macosx swiftc "${FLAGS[@]}" \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        -target "$(uname -m)-apple-macos26.0" \
        "$ROOT"/Sources/Math/*.swift "$ROOT"/Tests/main.swift \
        -o "$BUILD/obj/MathTests"
    "$BUILD/obj/MathTests"
fi

echo "==> Compiling $APP_NAME for $ARCH (iOS $MIN_IOS+ Simulator)"
xcrun --sdk iphonesimulator swiftc "${FLAGS[@]}" -sdk "$SDK" -parse-as-library \
    -target "$ARCH-apple-ios$MIN_IOS-simulator" \
    "$ROOT"/Sources/Math/*.swift "$ROOT"/Sources/App/*.swift \
    -o "$APP/$APP_NAME"

echo "==> Compiling the app icon"
cp "$ROOT/Icon/AppIcon.png" "$BUILD/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
cat > "$BUILD/Assets.xcassets/Contents.json" <<'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON
cat > "$BUILD/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images": [ { "filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" } ],
  "info": { "author": "xcode", "version": 1 }
}
JSON
xcrun actool "$BUILD/Assets.xcassets" \
    --compile "$APP" \
    --platform iphonesimulator \
    --minimum-deployment-target "$MIN_IOS" \
    --target-device iphone --target-device ipad \
    --app-icon AppIcon \
    --output-partial-info-plist "$BUILD/icon-info.plist" > "$BUILD/actool.log" 2>&1 \
    || { cat "$BUILD/actool.log"; exit 1; }

echo "==> Assembling $APP"
cp "$PLIST" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $BUILD/icon-info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleSupportedPlatforms array' \
    -c 'Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator' "$APP/Info.plist"
plutil -lint "$APP/Info.plist" > /dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
