#!/usr/bin/env bash
# Release build, assemble and sign `dist/Seat Gauge.app`.
#
# The fonts are copied by hand rather than declared as SwiftPM `resources:`:
# the generated accessor looks for its bundle beside the .app and at the
# absolute build path, neither of which exists in an installed copy, so an
# installed app built that way crashes on first font lookup.
#
# `--identifier` is passed explicitly because usernoted names a notification
# client by the code-signing identifier of the calling process, and a signature
# whose identifier does not match CFBundleIdentifier fails silently later.
# Signing is ad-hoc.
#
# The identifier is the argument: the real one by default, which is what
# `make install` builds, or the `.dev` one `make app` passes, which gives a
# clone's build its own support folder and defaults domain.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAME=SeatGauge
ID="${1:-com.launchastro.seatgauge}"
case "$ID" in
  com.launchastro.seatgauge|com.launchastro.seatgauge.dev) ;;
  *) printf 'build-app: %s is not com.launchastro.seatgauge or its .dev build. Nothing was built.\n' "$ID" >&2
     exit 1 ;;
esac
VER="$(tr -d '[:space:]' < VERSION)"
APP="dist/Seat Gauge.app"

swift build -c release
rm -rf "$APP"
mkdir -p dist
# Before the bundle exists, not after it: Spotlight indexes a new bundle as
# soon as it is written, and a marker that arrives later does not take the
# entry back. The installed copy should be the only one Spotlight finds.
touch dist/.metadata_never_index
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$NAME" "$APP/Contents/MacOS/"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Seat Gauge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - --identifier "$ID" "$APP"
printf 'built %s\n' "$APP"
