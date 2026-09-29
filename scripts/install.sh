#!/usr/bin/env bash
# Put the built app in /Applications, replacing only the copy this script
# installed there.
#
# One copy matters: `SMAppService` registers the bundle it is running from, and
# a second copy with the same bundle identifier can take the login item over.
# So another copy anywhere else is a refusal, listed for the user to remove,
# never something this script deletes. `/Applications` is also what keeps the
# app out of App Translocation.
#
# `SEATGAUGE_APPLICATIONS` and `SEATGAUGE_DIST` are here so the tests can run
# this script against a fake machine. Nothing else sets them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ID=com.launchastro.seatgauge
DIST="${SEATGAUGE_DIST:-dist}"
APP="$DIST/Seat Gauge.app"
APPLICATIONS="${SEATGAUGE_APPLICATIONS:-/Applications}"
DEST="$APPLICATIONS/Seat Gauge.app"

refuse() { printf 'install: %s\n' "$1" >&2; exit 1; }

# Refusals come before anything is removed, so a run that cannot finish leaves
# the installed app exactly as it was.
[ -d "$APP" ] ||
  refuse "$APP is not there. Run make app first. Nothing has been removed."
codesign --verify --strict "$APP" >/dev/null 2>&1 ||
  refuse "$APP is not signed, so it would not hold a login item. Nothing has been removed."
# mdfind is the only way another copy is found, and an index that is off
# answers with silence rather than with an error. That silence would read as
# no other copy, so it is a refusal. Recent macOS reports / as read-only, and
# that index still answers mdfind, so it counts as on. The status has to be
# exactly one of those two lines; anything else refuses.
status="$(mdutil -s / 2>/dev/null |
  sed -e '/^\/:$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' || true)"
case "$status" in
  'Indexing enabled.' | 'Index is read-only.') ;;
  *) refuse "Spotlight indexing is off on /, so other copies of the app cannot be found." ;;
esac

SOURCE="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
others=""
while IFS= read -r copy; do
  [ -n "$copy" ] || continue
  # The copy being installed from and the one being replaced are expected.
  [ "$copy" = "$SOURCE" ] || [ "$copy" = "$DEST" ] && continue
  others="$others  $copy"$'\n'
done <<COPIES
$(mdfind "kMDItemCFBundleIdentifier == $ID" 2>/dev/null || true)
COPIES
[ -z "$others" ] ||
  refuse "other copies of Seat Gauge are on this Mac. Move them to the Trash, then install again. Nothing has been removed."$'\n'"$others"

printf 'install: quitting any running copy\n'
pkill -x SeatGauge || true

rm -rf "$DEST"
mkdir -p "$APPLICATIONS"
ditto "$APP" "$DEST"
# dist/ is emptied of the copy it was built from, so Spotlight finds one copy.
rm -rf "$APP"
open "$DEST"
printf 'install: %s\n' "$DEST"
