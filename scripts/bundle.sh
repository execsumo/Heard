#!/bin/bash
set -euo pipefail

# Build Lurk.app from Swift Package Manager output.
# Usage: ./scripts/bundle.sh [--release] [--sign IDENTITY]
#
# Options:
#   --release     Build in release mode (optimized)
#   --sign ID     Code sign with the given identity (e.g., "Developer ID Application: ...")
#   --output DIR  Output directory for the .app bundle (default: ./build)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="debug"
SIGN_IDENTITY=""
OUTPUT_DIR="$REPO_ROOT/build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)  BUILD_CONFIG="release"; shift ;;
        --sign)     SIGN_IDENTITY="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

APP_NAME="Lurk"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME ($BUILD_CONFIG)..."
if [[ "$BUILD_CONFIG" == "release" ]]; then
    swift build -c release --package-path "$REPO_ROOT"
    BINARY="$REPO_ROOT/.build/release/$APP_NAME"
else
    swift build --package-path "$REPO_ROOT"
    BINARY="$REPO_ROOT/.build/debug/$APP_NAME"
fi

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

echo "==> Creating app bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$REPO_ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Copy entitlements (for reference; used during signing)
cp "$REPO_ROOT/Lurk.entitlements" "$APP_BUNDLE/Contents/Resources/Lurk.entitlements"

# Code sign if identity provided
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with identity: $SIGN_IDENTITY"
    codesign --force --options runtime \
        --entitlements "$REPO_ROOT/Lurk.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
    echo "==> Verifying signature..."
    codesign --verify --verbose "$APP_BUNDLE"
else
    # Ad-hoc sign so macOS will run it locally
    echo "==> Ad-hoc signing..."
    codesign --force --sign - \
        --entitlements "$REPO_ROOT/Lurk.entitlements" \
        "$APP_BUNDLE"
fi

echo ""
echo "==> Done! App bundle created at:"
echo "    $APP_BUNDLE"
echo ""
echo "    To run:  open $APP_BUNDLE"
echo "    To install: cp -r $APP_BUNDLE /Applications/"
