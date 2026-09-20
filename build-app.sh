#!/bin/sh
set -eu

swift build -c release
APP_DIR="$(pwd)/FanBar.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/FanBar "$APP_DIR/Contents/MacOS/FanBar"
mkdir -p "$APP_DIR/Contents/Library/PrivilegedHelperTools"
cp .build/release/FanBarHelper "$APP_DIR/Contents/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper"
mkdir -p "$APP_DIR/Contents/Library/LaunchDaemons"
cp Resources/com.webtiara.fanbar.helper.plist "$APP_DIR/Contents/Library/LaunchDaemons/com.webtiara.fanbar.helper.plist"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/FanBar"
echo "$APP_DIR"
