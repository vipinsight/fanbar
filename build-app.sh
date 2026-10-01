#!/bin/sh
# Builds a universal FanBar.app.
#
# Local builds are ad-hoc signed and never update themselves. scripts/release.sh
# passes a Developer ID through SIGN_IDENTITY to make a build Apple will notarize.
set -eu

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP_DIR="$(pwd)/FanBar.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" \
  "$CONTENTS/Library/PrivilegedHelperTools" "$CONTENTS/Library/LaunchDaemons"
cp "$BIN/FanBar" "$CONTENTS/MacOS/FanBar"
cp "$BIN/FanBarHelper" "$CONTENTS/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper"
cp Resources/com.webtiara.fanbar.helper.plist "$CONTENTS/Library/LaunchDaemons/com.webtiara.fanbar.helper.plist"
cp Resources/Info.plist "$CONTENTS/Info.plist"
ditto "$BIN/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$CONTENTS/MacOS/FanBar"

# Sign inside out. Notarization needs the hardened runtime and a secure
# timestamp; an ad-hoc identity cannot take a timestamp.
sign() {
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$@"
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"
  fi
}
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$CONTENTS/Frameworks/Sparkle.framework"
sign --identifier com.webtiara.fanbar.helper "$CONTENTS/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper"
sign "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
