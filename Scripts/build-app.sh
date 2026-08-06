#!/usr/bin/env bash
# Build overscroll and assemble it into a real .app bundle.
#
# The bundle is not cosmetic. TCC (Accessibility, Screen Recording, Automation) records grants
# against a bundle identifier plus a code signature, so a bare SPM binary either cannot hold the
# permissions or loses them constantly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Overscroll"
BUNDLE_ID="com.itsmaleen.overscroll"
CONFIG="${CONFIG:-release}"

# Default install location is a stable path on purpose — see the TCC note at the bottom.
# /Applications when writable: TCC grants are tied to the path as well as the signature, and the
# System Settings file picker opens there, which matters when an app has to be added by hand.
if [ -z "${DEST:-}" ] && [ -w /Applications ]; then
    DEST="/Applications"
fi
DEST="${DEST:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

# Signing identity. This is not cosmetic: macOS keys TCC grants to the code signature, so an
# ad-hoc signature — whose hash changes on every build — makes you re-approve Accessibility and
# Screen Recording after every single rebuild. A stable identity keeps the grants.
#
# Prefer a Developer ID if the keychain has one, then any Apple Development cert, then ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Building ($CONFIG)"
cd "$ROOT"
swift build -c "$CONFIG" --product overscroll

BINARY="$(swift build -c "$CONFIG" --product overscroll --show-bin-path)/overscroll"
[ -f "$BINARY" ] || { echo "build produced no binary at $BINARY" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Screen Clip</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>

    <!-- Menu-bar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key><true/>

    <!-- Required to read the frontmost tab's real URL out of a browser via Apple Events. Without
         this key the app is killed outright the first time it tries, rather than being denied. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Screen Clip reads the frontmost tab's URL so captured clips record where they came from.</string>
</dict>
</plist>
PLIST

echo "==> Signing (identity: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1 \
    || codesign --force --sign - "$APP"

echo "==> Done: $APP"
echo
echo "Launch:  open \"$APP\""
echo
echo "First run needs two grants in System Settings > Privacy & Security:"
echo "  · Accessibility    — required. Reads other apps' text and posts scroll events."
echo "  · Screen Recording — optional. Only for the OCR fallback and keeping the image."
echo
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "NOTE: ad-hoc signed. macOS ties TCC grants to the code signature, so every rebuild"
    echo "      invalidates them and you will have to re-approve. To avoid that, make a"
    echo "      self-signed certificate in Keychain Access and rebuild with:"
    echo "          SIGN_IDENTITY=\"Your Cert Name\" ./Scripts/build-app.sh"
fi
