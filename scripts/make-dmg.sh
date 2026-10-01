#!/bin/bash
# Wraps an app in a drag-to-install disk image: the app on the left, an
# Applications link on the right, and the arrow background between them.
#
#   scripts/make-dmg.sh FanBar.app dist/FanBar.dmg
#
# Finder lays out the window, so this needs a logged-in session and lets
# Terminal control Finder the first time it runs. Signing and notarizing the
# image is up to the caller (scripts/release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"
DMG="$2"
VOLUME="FanBar"
BACKGROUND=Resources/dmg/background.tiff

[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
[ -f "$BACKGROUND" ] || { echo "Missing $BACKGROUND (run scripts/generate-dmg-background.swift)" >&2; exit 1; }
# Finder finds the window by volume name, so another mounted FanBar would get the layout instead.
[ ! -e "/Volumes/$VOLUME" ] || { echo "Eject /Volumes/$VOLUME first" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir "$WORK/stage"
ditto "$APP" "$WORK/stage/$(basename "$APP")"
ln -s /Applications "$WORK/stage/Applications"
mkdir "$WORK/stage/.background"
cp "$BACKGROUND" "$WORK/stage/.background/background.tiff"

hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" -quiet
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -quiet

# Window and icon positions match the background (720x400, icons at y 175).
osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 920, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$(basename "$APP")" of container window to {170, 175}
    set position of item "Applications" of container window to {550, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Finder writes .DS_Store on its own schedule; wait for it before ejecting.
for _ in $(seq 1 20); do
  [ -f "/Volumes/$VOLUME/.DS_Store" ] && break
  sleep 0.5
done
[ -f "/Volumes/$VOLUME/.DS_Store" ] || { echo "Finder did not save the window layout" >&2; exit 1; }
sync
hdiutil detach "/Volumes/$VOLUME" -quiet

mkdir -p "$(dirname "$DMG")"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" -quiet
echo "$DMG"
