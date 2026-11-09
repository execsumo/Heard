#!/bin/bash
set -euo pipefail

# Build Heard.app; optionally install it to /Applications and launch it.
# Usage: ./scripts/bundle.sh [--release] [--sign IDENTITY] [--stage-only]
#
# Options:
#   --release              Build in release mode (optimized)
#   --sign ID              Code sign with the given identity
#   --output DIR           Output directory for the staging .app bundle (default: ./build)
#   --stage-only           Build and sign without touching the installed app or TCC
#   --allow-signing-change Explicitly allow replacing an app with a different signer
#   --reset                Reset privacy grants and saved window sizes before launch

BUNDLE_ID="com.execsumo.heard"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="debug"
SIGN_IDENTITY=""
OUTPUT_DIR="$REPO_ROOT/build"
RESET_TCC=0
STAGE_ONLY=0
ALLOW_SIGNING_CHANGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)              BUILD_CONFIG="release"; shift ;;
        --sign)                 SIGN_IDENTITY="$2"; shift 2 ;;
        --output)               OUTPUT_DIR="$2"; shift 2 ;;
        --stage-only)           STAGE_ONLY=1; shift ;;
        --allow-signing-change) ALLOW_SIGNING_CHANGE=1; shift ;;
        --reset)                RESET_TCC=1; shift ;;
        *)            echo "Unknown option: $1"; exit 1 ;;
    esac
done

APP_NAME="Heard"
# Resolve the output path before deleting its previous build: staging directly
# over /Applications/Heard.app would bypass the install and signer safeguards.
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
INSTALLED="$(cd /Applications && pwd -P)/$APP_NAME.app"
# The repository root is resolved dynamically.
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/bundle-safety.sh"

if [[ "$APP_BUNDLE" == "$INSTALLED" ]]; then
    echo "ERROR: The staging bundle cannot be the installed app. Choose another --output directory."
    exit 1
fi
if [[ "$STAGE_ONLY" -eq 1 && "$RESET_TCC" -eq 1 ]]; then
    echo "ERROR: --stage-only cannot be combined with --reset."
    exit 1
fi
if [[ "$STAGE_ONLY" -eq 0 ]] && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "ERROR: Heard is running. Stop the recording, let it queue, and quit Heard before installing."
    echo "       Use --stage-only to build without interrupting it."
    exit 1
fi

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

# Copy bundled fonts. Info.plist's ATSApplicationFontsPath points at Contents/Resources/Fonts,
# which is how JetBrains Mono becomes available to the app without installing it system-wide.
echo "==> Copying fonts..."
mkdir -p "$APP_BUNDLE/Contents/Resources/Fonts"
cp "$REPO_ROOT/Resources/Fonts/"*.ttf "$APP_BUNDLE/Contents/Resources/Fonts/"
cp "$REPO_ROOT/Resources/Fonts/OFL.txt" "$APP_BUNDLE/Contents/Resources/Fonts/"

# Auto-detect a Developer ID identity, without hard-coding a person's name or
# exposing the certificate. If multiple identities are available, require an
# explicit choice rather than silently changing the installed app's identity.
if [[ -z "$SIGN_IDENTITY" ]]; then
    developer_identities=$(security find-identity -v -p codesigning | grep '"Developer ID Application:' || true)
    developer_count=$(printf '%s\n' "$developer_identities" | grep -c '"Developer ID Application:' || true)
    if [[ "$developer_count" -gt 1 ]]; then
        echo "ERROR: Multiple Developer ID identities found. Select one with --sign."
        exit 1
    elif [[ "$developer_count" -eq 1 ]]; then
        SIGN_IDENTITY=$(printf '%s\n' "$developer_identities" | cut -d '"' -f 2)
        echo "==> Using the available Developer ID Application identity"
    elif security find-identity -v -p codesigning | grep -q '"Dev Cert"'; then
        SIGN_IDENTITY="Dev Cert"
        echo "==> Using the available development identity"
    fi
fi

# Code sign
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Signing the app bundle"
    # Developer ID Application certs (issued by Apple) require --options runtime (Hardened
    # Runtime) and --timestamp for notarization. Self-signed / local certs must NOT use
    # --options runtime: macOS performs stricter CT/chain validation that fails for non-Apple
    # certs, causing TCC (Accessibility, Screen Recording) to not persist across restarts.
    sign_bundle() {
        codesign --force "$@" \
            --entitlements "$REPO_ROOT/Heard.entitlements" \
            --sign "$SIGN_IDENTITY" \
            "$APP_BUNDLE"
    }
    if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
        sign_bundle --options runtime --timestamp
    else
        sign_bundle
    fi
    echo "==> Verifying signature..."
    codesign --verify --verbose "$APP_BUNDLE"
    echo "    If macOS rejects a permission, inspect its System Settings entry first."
    echo "    A signing change can require re-adding Heard; do not reset unrelated grants."
else
    # Ad-hoc sign so macOS will run it locally
    echo "==> Ad-hoc signing (no 'Dev Cert' found)..."
    codesign --force --sign - \
        --entitlements "$REPO_ROOT/Heard.entitlements" \
        "$APP_BUNDLE"
fi

if [[ "$STAGE_ONLY" -eq 1 ]]; then
    echo "==> Staged build only; installed app and permissions were not changed."
    exit 0
fi

# Check again after the build in case a meeting started while it was compiling.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "ERROR: Heard started while building. Stop its recording and quit before installing."
    exit 1
fi
if [[ -d "$INSTALLED" ]] && ! heard_signing_compatible "$INSTALLED" "$APP_BUNDLE"; then
    if [[ "$ALLOW_SIGNING_CHANGE" -ne 1 ]]; then
        echo "ERROR: The staged build does not satisfy the installed app's signing requirement."
        echo "       Replacing it can invalidate Accessibility and other macOS grants."
        echo "       Use the same signing identity, or explicitly pass --allow-signing-change."
        exit 1
    fi
    echo "WARNING: Installing with a different signing identity; macOS may require reauthorization."
fi

echo "==> Installing to $INSTALLED..."
# Copy first and keep the previous app so a failed replacement can be rolled back.
install_stage=$(mktemp -d /Applications/.heard-install.XXXXXX)
ditto "$APP_BUNDLE" "$install_stage/$APP_NAME.app"
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    rm -rf "$install_stage"
    echo "ERROR: Heard started during installation preparation. Stop its recording and quit before installing."
    exit 1
fi
backup_dir=""
if [[ -d "$INSTALLED" ]]; then
    backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/heard-before-install.XXXXXX")
    mv "$INSTALLED" "$backup_dir/$APP_NAME.app"
fi
if ! mv "$install_stage/$APP_NAME.app" "$INSTALLED"; then
    if [[ -n "$backup_dir" ]]; then
        mv "$backup_dir/$APP_NAME.app" "$INSTALLED" || echo "ERROR: Restore the prior app from $backup_dir."
    fi
    echo "ERROR: Could not install the staged app."
    exit 1
fi
if ! codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1 ||
   ! cmp -s "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$INSTALLED/Contents/MacOS/$APP_NAME"; then
    mv "$INSTALLED" "$install_stage/failed-$APP_NAME.app"
    if [[ -n "$backup_dir" ]]; then
        mv "$backup_dir/$APP_NAME.app" "$INSTALLED" || echo "ERROR: Restore the prior app from $backup_dir."
    fi
    echo "ERROR: Installed app failed verification; the prior app was restored when available."
    exit 1
fi
rmdir "$install_stage"
if [[ -n "$backup_dir" ]]; then
    echo "==> Previous app backed up at $backup_dir/$APP_NAME.app"
fi

# A requested reset happens only after installation succeeds; failures are
# visible rather than being reported as successful resets.
if [[ "$RESET_TCC" -eq 1 ]]; then
    echo "==> Resetting TCC grants for $BUNDLE_ID..."
    for service in Microphone ScreenCapture Accessibility AudioCapture; do
        if ! tccutil reset "$service" "$BUNDLE_ID"; then
            echo "WARNING: Could not reset $service; inspect its System Settings entry."
        fi
    done
    defaults delete "$BUNDLE_ID" screenCaptureTCCGranted 2>/dev/null || true
    defaults delete "$BUNDLE_ID" audioCaptureTCCGranted 2>/dev/null || true
    echo "==> Resetting saved window sizes for $BUNDLE_ID..."
    defaults delete "$BUNDLE_ID" "NSWindow Frame settings" 2>/dev/null || true
    defaults delete "$BUNDLE_ID" "NSWindow Frame speaker-naming" 2>/dev/null || true
fi

echo "==> Launching $INSTALLED..."
open "$INSTALLED"

echo ""
echo "    Grant permissions in System Settings → Privacy & Security, then"
echo "    fully quit $APP_NAME from the menu bar and relaunch it — Screen"
echo "    Recording grants do not apply to a process that was already running."
