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
# Signing is ad-hoc. `seatgauge-cli` ships inside the bundle, in
# Contents/Helpers where it takes no bundle identity of its own, and is signed
# first so the app's signature seals it.
#
# The bundle is put together and signed in a scratch folder, then copied into
# `dist/` without extended attributes. A checkout in a synced folder such as
# iCloud Drive gets Finder and file provider attributes on a new bundle within
# seconds, and codesign refuses to sign or verify a bundle carrying them. `cp -X`
# keeps any such attributes on the sources out of the bundle too.
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
scratch="$(mktemp -d "${TMPDIR:-/tmp}/seat-gauge-build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
touch "$scratch/.metadata_never_index"
BUNDLE="$scratch/Seat Gauge.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Helpers" "$BUNDLE/Contents/Resources"
cp -X ".build/release/$NAME" "$BUNDLE/Contents/MacOS/"
cp -X .build/release/seatgauge-cli "$BUNDLE/Contents/Helpers/"
cp -RX Resources/Fonts "$BUNDLE/Contents/Resources/Fonts"
cp -X Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
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

codesign --force --sign - --identifier seatgauge-cli "$BUNDLE/Contents/Helpers/seatgauge-cli"
codesign --force --sign - --identifier "$ID" "$BUNDLE"
codesign --verify --strict "$BUNDLE"

rm -rf "$APP"
mkdir -p dist
# Before the bundle exists, not after it: Spotlight indexes a new bundle as
# soon as it is written, and a marker that arrives later does not take the
# entry back. The installed copy should be the only one Spotlight finds.
touch dist/.metadata_never_index
ditto --norsrc --noextattr --noacl "$BUNDLE" "$APP"
printf 'built %s\n' "$APP"
