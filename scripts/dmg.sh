#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package Heard.app into a distributable DMG.
#
# Prerequisites (one-time setup):
#   1. Install a "Developer ID Application" certificate via Keychain Access +
#      developer.apple.com/account/resources/certificates/add
#   2. Generate an App Store Connect API key (role: Developer) and store it:
#        xcrun notarytool store-credentials "heard-notary" \
#          --key ~/.apple/AuthKey_XXXX.p8 \
#          --key-id XXXX \
#          --issuer YOUR-ISSUER-UUID
#
# Usage:
#   ./scripts/dmg.sh --sign "Developer ID Application: Your Name (TEAMID)"
#   ./scripts/dmg.sh --sign "Developer ID Application: ..." --notary-profile heard-notary
#   ./scripts/dmg.sh --sign "..." --output dist/
#
# Options:
#   --sign ID              Developer ID Application identity (required)
#   --notary-profile P     Keychain profile for notarytool (default: heard-notary; local use)
#   --api-key-path PATH    Path to .p8 API key file (CI use; overrides --notary-profile)
#   --api-key-id ID        App Store Connect API key ID (required with --api-key-path)
#   --api-issuer-id UUID   App Store Connect issuer UUID (required with --api-key-path)
#   --output DIR           Directory to write the final DMG (default: ./dist)
#   --skip-notarize        Build and package without notarizing (local testing only)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY=""
NOTARY_PROFILE="heard-notary"
API_KEY_PATH=""
API_KEY_ID=""
API_ISSUER_ID=""
OUTPUT_DIR="$REPO_ROOT/dist"
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)           SIGN_IDENTITY="$2"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        --api-key-path)   API_KEY_PATH="$2"; shift 2 ;;
        --api-key-id)     API_KEY_ID="$2"; shift 2 ;;
        --api-issuer-id)  API_ISSUER_ID="$2"; shift 2 ;;
        --output)         OUTPUT_DIR="$2"; shift 2 ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        *)                echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Build notarytool auth flags — API key takes precedence over keychain profile
if [[ -n "$API_KEY_PATH" ]]; then
    NOTARY_AUTH=(--key "$API_KEY_PATH" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID")
else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "ERROR: --sign is required."
    echo "  Run: security find-identity -v -p codesigning | grep 'Developer ID'"
    exit 1
fi

if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "ERROR: Identity must be a 'Developer ID Application' certificate for distribution."
    echo "  Got: $SIGN_IDENTITY"
    exit 1
fi

APP_NAME="Heard"
BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Read version from Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$REPO_ROOT/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

mkdir -p "$OUTPUT_DIR"

# ── 1. Build release .app (bundle.sh now adds --options runtime --timestamp for Developer ID)
echo "==> Building release app bundle..."
"$REPO_ROOT/scripts/bundle.sh" --release --sign "$SIGN_IDENTITY" --output "$BUILD_DIR" --stage-only

echo ""
echo "==> Verifying hardened runtime..."
codesign --display --verbose=4 "$APP_BUNDLE" 2>&1 | grep -E "(flags|runtime|Authority)" || true
codesign --verify --deep --strict "$APP_BUNDLE"

# ── 2. Notarize the .app
# notarytool requires a zip, pkg, or dmg — bare .app bundles are rejected.
# Zip the app, submit the zip, then staple the .app directly.
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    APP_ZIP="$OUTPUT_DIR/${APP_NAME}-${VERSION}.app.zip"
    echo ""
    echo "==> Zipping $APP_NAME.app for notarization submission..."
    ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"

    echo "==> Notarizing $APP_NAME.app (this takes ~1–2 minutes)..."
    xcrun notarytool submit "$APP_ZIP" \
        "${NOTARY_AUTH[@]}" \
        --wait
    rm -f "$APP_ZIP"

    echo "==> Stapling notarization ticket to $APP_NAME.app..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
fi

# ── 3. Create DMG
echo ""
echo "==> Creating DMG: $DMG_NAME..."
# Remove any stale DMG from a previous run
rm -f "$DMG_PATH"

# Build a temporary uncompressed image first so we can add an Applications symlink
TEMP_DMG="$OUTPUT_DIR/.tmp_heard.dmg"
rm -f "$TEMP_DMG"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_BUNDLE" \
    -ov \
    -format UDRW \
    "$TEMP_DMG"

# Mount, add /Applications symlink, then unmount
MOUNT_POINT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen | \
    awk 'END {print $NF}')
ln -sf /Applications "$MOUNT_POINT/Applications"
hdiutil detach "$MOUNT_POINT" -quiet

# Convert to final compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$TEMP_DMG"

# ── 4. Sign the DMG
echo "==> Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

# ── 5. Notarize and staple the DMG
if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    echo ""
    echo "==> Notarizing DMG (this takes ~1–2 minutes)..."
    xcrun notarytool submit "$DMG_PATH" \
        "${NOTARY_AUTH[@]}" \
        --wait

    echo "==> Stapling notarization ticket to DMG..."
    xcrun stapler staple "$DMG_PATH"
fi

# ── 6. Final verification
echo ""
echo "==> Verifying app..."
spctl --assess --verbose=4 --type execute "$APP_BUNDLE" 2>&1 || true

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
    echo "==> Verifying DMG..."
    spctl --assess --verbose=4 --type open --context context:primary-signature "$DMG_PATH" 2>&1 || true
fi

# ── 7. Print SHA256 for Homebrew Cask
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
echo "=========================================="
echo "  Done: $DMG_PATH"
echo "  Version: $VERSION"
echo "  SHA256:  $SHA256"
echo ""
echo "  Next: upload to GitHub Releases as v${VERSION}"
echo "  Then update Casks/heard.rb:"
echo "    sha256 \"$SHA256\""
echo "    version \"$VERSION\""
echo "=========================================="
