#!/bin/bash
set -euo pipefail

# Build Heard.app from Swift Package Manager output.
# Usage: ./scripts/bundle.sh [--release] [--sign IDENTITY] [--install] [--reset-tcc]
#
# Options:
#   --release     Build in release mode (optimized)
#   --sign ID     Code sign with the given identity (e.g., "Developer ID Application: ...")
#   --output DIR  Output directory for the .app bundle (default: ./build)
#   --install     Quit any running Heard, replace /Applications/Heard.app with the
#                 fresh build, and relaunch it. Installing to a stable path keeps TCC
#                 grants attached to a single bundle across rebuilds.
#   --reset       Reset Microphone, Screen Recording, Accessibility, and AudioCapture
#                 grants for com.execsumo.heard before launch. Implies --install.

BUNDLE_ID="com.execsumo.heard"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="debug"
SIGN_IDENTITY=""
OUTPUT_DIR="$REPO_ROOT/build"
INSTALL=0
RESET_TCC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)    BUILD_CONFIG="release"; shift ;;
        --sign)       SIGN_IDENTITY="$2"; shift 2 ;;
        --output)     OUTPUT_DIR="$2"; shift 2 ;;
        --install)    INSTALL=1; shift ;;
        --reset)      RESET_TCC=1; INSTALL=1; shift ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

APP_NAME="Heard"
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
cp "$REPO_ROOT/Heard.entitlements" "$APP_BUNDLE/Contents/Resources/Heard.entitlements"

# Compile and copy app icon
echo "==> Compiling AppIcon.icns..."
iconutil -c icns "$REPO_ROOT/Resources/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy menu bar template image (SVG; NSImage renders it sharp at any resolution)
cp "$REPO_ROOT/Resources/MenuBarIconTemplate.svg" "$APP_BUNDLE/Contents/Resources/"

# Auto-detect "Dev Cert" if no identity explicitly provided
if [[ -z "$SIGN_IDENTITY" ]]; then
    if security find-identity -v -p codesigning | grep -q '"Dev Cert"'; then
        SIGN_IDENTITY="Dev Cert"
        echo "==> Found 'Dev Cert' — using it for signing"
    fi
fi

# Code sign
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing with identity: $SIGN_IDENTITY"
    # NOTE: --options runtime (Hardened Runtime) is intentionally omitted for self-signed
    # certificates. When Hardened Runtime is enabled with a non-Apple-Developer cert, macOS
    # performs a stricter CT/chain validation that fails for self-signed certs, causing TCC
    # (Accessibility, Screen Recording) to not persist across app restarts. Without the flag
    # the entitlements are still embedded and TCC correctly tracks the cert identity.
    codesign --force \
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
echo "==> Done! App bundle created at:"
echo "    $APP_BUNDLE"

if [[ "$INSTALL" -eq 1 ]]; then
    INSTALLED="/Applications/$APP_NAME.app"

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
else
    echo ""
    echo "    To run:  open $APP_BUNDLE"
    echo "    To install: ./scripts/bundle.sh --install"
fi
