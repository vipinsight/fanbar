#!/bin/bash
# Builds, signs, and notarizes a FanBar release, then writes the three files
# to upload. See docs/release.md.
#
# It stops unless notarization credentials and the Sparkle key are present,
# rather than producing a release that looks fine and updates nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="vipinsight/fanbar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
MINIMUM_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
DIST="dist/$VERSION"
SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update
# The private half of SUPublicEDKey. It is never in the repository, and it
# cannot be replaced: installed copies trust only the key compiled into them.
KEY_FILE="${FANBAR_SPARKLE_KEY:-$HOME/Library/CloudStorage/OneDrive-Personal/keys/macos-dev/fanbar-sparkle.key}"

# Credentials come from .env.notarization (gitignored); exported variables win.
if [ -f .env.notarization ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"; value="${value#\"}"; value="${value%\'}"; value="${value#\'}"
    [ -n "${!key:-}" ] || export "$key=$value"
  done < .env.notarization
fi
for name in APPLE_ID APPLE_TEAM_ID APPLE_PASSWORD APPLE_SIGNING_IDENTITY; do
  [ -n "${!name:-}" ] || { echo "Missing $name: export it or add it to .env.notarization" >&2; exit 1; }
done
[ -f "$KEY_FILE" ] || { echo "Missing Sparkle key at $KEY_FILE (or set FANBAR_SPARKLE_KEY)" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_PASSWORD" --wait
}

rm -rf "$DIST"
mkdir -p "$DIST"
SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY" ./build-app.sh

# 1. Notarize and staple the app, so it opens without a network check.
ditto -c -k --keepParent FanBar.app "$DIST/notarize.zip"
notarize "$DIST/notarize.zip"
rm "$DIST/notarize.zip"
xcrun stapler staple FanBar.app
spctl --assess --type execute --verbose FanBar.app

# 2. The update payload installed copies download.
ZIP="$DIST/FanBar-$VERSION.zip"
ditto -c -k --keepParent FanBar.app "$ZIP"

# 3. The disk image for new installs. Gatekeeper rejects an unnotarized image
# even when the app inside it is notarized.
DMG="$DIST/FanBar-$VERSION.dmg"
STAGE=$(mktemp -d)
ditto FanBar.app "$STAGE/FanBar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname FanBar -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

# 4. The feed installed copies read from releases/latest/download/appcast.xml.
# sign_update prints: sparkle:edSignature="..." length="..."
ENCLOSURE=$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP")
cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>FanBar</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_OS</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/FanBar-$VERSION.zip" type="application/octet-stream" $ENCLOSURE />
    </item>
  </channel>
</rss>
EOF

cat <<EOF

Release files:
  $DMG
  $ZIP
  $DIST/appcast.xml

Publish all three together:
  gh release create v$VERSION --repo $REPO --target main $DMG $ZIP $DIST/appcast.xml
EOF
