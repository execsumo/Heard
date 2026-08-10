#!/bin/bash
set -euo pipefail

# Build Heard.app, install it to /Applications, and relaunch.
# Usage: ./scripts/bundle.sh [--release] [--sign IDENTITY] [--reset]
#
# Options:
#   --release     Build in release mode (optimized)
#   --sign ID     Code sign with the given identity (e.g., "Developer ID Application: ...")
#   --output DIR  Output directory for the staging .app bundle (default: ./build)
#   --reset       Reset Microphone, Screen Recording, Accessibility, and AudioCapture
#                 grants for com.execsumo.heard before launch.

BUNDLE_ID="com.execsumo.heard"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="debug"
SIGN_IDENTITY=""
OUTPUT_DIR="$REPO_ROOT/build"
RESET_TCC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)    BUILD_CONFIG="release"; shift ;;
        --sign)       SIGN_IDENTITY="$2"; shift 2 ;;
        --output)     OUTPUT_DIR="$2"; shift 2 ;;
        --reset)      RESET_TCC=1; shift ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

APP_NAME="Heard"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"

echo "==> Cleaning previous build artifacts..."
swift package clean --package-path "$REPO_ROOT"

echo "==> Building $APP_NAME ($BUILD_CONFIG)..."
if [[ "$BUILD_CONFIG" == "release" ]]; then
    # --product Heard: a bare `swift build` also builds HeardTests, whose
    # @testable import HeardCore fails to compile in release mode (testability
    # isn't enabled), which previously broke every release build silently.
    swift build -c release --product "$APP_NAME" --package-path "$REPO_ROOT"
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
cp "$REPO_ROOT/Heard.entitlements" "$APP_BUNDLE/Contents/Resources/Heard.entitlements"

# Compile and copy app icon
echo "==> Compiling AppIcon.icns..."
iconutil -c icns "$REPO_ROOT/Resources/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy menu bar template image (SVG; NSImage renders it sharp at any resolution)
cp "$REPO_ROOT/Resources/MenuBarIconTemplate.svg" "$APP_BUNDLE/Contents/Resources/"

# Auto-detect signing identity if not explicitly provided.
# Prefer Developer ID Application (stable TCC grants across rebuilds), fall back to Dev Cert.
if [[ -z "$SIGN_IDENTITY" ]]; then
    if security find-identity -v -p codesigning | grep -q '"Developer ID Application: Herwin Gill"'; then
        SIGN_IDENTITY="Developer ID Application: Herwin Gill (577WHA43TF)"
        echo "==> Using Developer ID Application cert"
    elif security find-identity -v -p codesigning | grep -q '"Dev Cert"'; then
        SIGN_IDENTITY="Dev Cert"
        echo "==> Found 'Dev Cert' — using it for signing"
    fi
fi

# Code sign
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with identity: $SIGN_IDENTITY"
    # Developer ID Application certs (issued by Apple) require --options runtime (Hardened
    # Runtime) and --timestamp for notarization. Self-signed / local certs must NOT use
    # --options runtime: macOS performs stricter CT/chain validation that fails for non-Apple
    # certs, causing TCC (Accessibility, Screen Recording) to not persist across restarts.
    CODESIGN_EXTRA_FLAGS=""
    if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
        CODESIGN_EXTRA_FLAGS="--options runtime --timestamp"
    fi
    codesign --force \
        $CODESIGN_EXTRA_FLAGS \
        --entitlements "$REPO_ROOT/Heard.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE"
    echo "==> Verifying signature..."
    codesign --verify --verbose "$APP_BUNDLE"
    echo ""
    echo "    NOTE: After each rebuild, you may need to re-grant TCC permissions."
    echo "    If permissions show 'Grant' after restart, run:"
    echo "      tccutil reset Accessibility com.execsumo.heard"
    echo "      tccutil reset ScreenCapture com.execsumo.heard"
    echo "      tccutil reset AudioCapture com.execsumo.heard"
    echo "    Then re-grant in System Settings → Privacy & Security."
else
    # Ad-hoc sign so macOS will run it locally
    echo "==> Ad-hoc signing (no 'Dev Cert' found)..."
    codesign --force --sign - \
        --entitlements "$REPO_ROOT/Heard.entitlements" \
        "$APP_BUNDLE"
fi

echo ""
echo "==> Quitting any running $APP_NAME..."
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "$APP_NAME" 2>/dev/null || true
# Give launchd a moment to release the bundle before we replace it.
sleep 1

if [[ "$RESET_TCC" -eq 1 ]]; then
    echo "==> Resetting TCC grants for $BUNDLE_ID..."
    tccutil reset Microphone "$BUNDLE_ID" || true
    tccutil reset ScreenCapture "$BUNDLE_ID" || true
    tccutil reset Accessibility "$BUNDLE_ID" || true
    tccutil reset AudioCapture "$BUNDLE_ID" || true
    # Also clear the UserDefaults keys that persist confirmed-granted state across
    # app restarts — without this, the app would still show permissions as Granted
    # after a --reset, because the cached UserDefaults values survive tccutil.
    defaults delete "$BUNDLE_ID" screenCaptureTCCGranted 2>/dev/null || true
    defaults delete "$BUNDLE_ID" audioCaptureTCCGranted 2>/dev/null || true
fi

echo "==> Installing to $INSTALLED..."
rm -rf "$INSTALLED"
cp -R "$APP_BUNDLE" "$INSTALLED"

echo "==> Launching $INSTALLED..."
open "$INSTALLED"

echo ""
echo "    Grant permissions in System Settings → Privacy & Security, then"
echo "    fully quit $APP_NAME from the menu bar and relaunch it — Screen"
echo "    Recording grants do not apply to a process that was already running."
