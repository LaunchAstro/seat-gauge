#!/usr/bin/env bash
# Put the built app in /Applications, replacing only the copy this script
# installed there, and link `seatgauge-cli` into `~/.local/bin`.
#
# One copy matters: `SMAppService` registers the bundle it is running from, and
# a second copy with the same bundle identifier can take the login item over.
# So another copy anywhere else is a refusal, listed for the user to remove,
# never something this script deletes. `/Applications` is also what keeps the
# app out of App Translocation.
#
# A checkout can sit in a synced folder such as iCloud Drive, which tags the
# bundle in `dist/` with Finder and file provider attributes a strict signature
# check refuses. So the bundle is copied without them to a scratch folder,
# checked there, and that clean copy is the one installed.
#
# The CLI is a link to the copy inside the installed app, so it updates with
# the app and needs no sudo. A link of exactly that shape is the only thing at
# its destination this script treats as its own.
#
# `SEATGAUGE_APPLICATIONS`, `SEATGAUGE_DIST` and `SEATGAUGE_BIN` are here so the
# tests can run this script against a fake machine. Nothing else sets them.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ID=com.launchastro.seatgauge
DIST="${SEATGAUGE_DIST:-dist}"
APP="$DIST/Seat Gauge.app"
APPLICATIONS="${SEATGAUGE_APPLICATIONS:-/Applications}"
DEST="$APPLICATIONS/Seat Gauge.app"
HELPER="Contents/Helpers/seatgauge-cli"
BIN="${SEATGAUGE_BIN:-$HOME/.local/bin}"
LINK="$BIN/seatgauge-cli"

refuse() { printf 'install: %s\n' "$1" >&2; exit 1; }

# Refusals come before anything is removed, so a run that cannot finish leaves
# the installed app exactly as it was.
[ -d "$APP" ] ||
  refuse "$APP is not there. Run make install, which builds it first. Nothing has been removed."
[ -f "$APP/$HELPER" ] ||
  refuse "$APP has no seatgauge-cli in it. Run make install, which builds both. Nothing has been removed."
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$DEST/$HELPER" ] ||
    refuse "$LINK is already there, and this script did not put it there. Move it away, then install again. Nothing has been removed."
fi
[ ! -e "$BIN" ] || [ -d "$BIN" ] ||
  refuse "$BIN is a file, not a folder, so seatgauge-cli cannot go in it. Nothing has been removed."
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

# After the search, so Spotlight has had no chance to report the clean copy.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/seat-gauge-install.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
CLEAN="$scratch/Seat Gauge.app"
touch "$scratch/.metadata_never_index"
ditto --norsrc --noextattr --noacl "$APP" "$CLEAN"
codesign --verify --strict "$CLEAN" >/dev/null 2>&1 ||
  refuse "$APP is not signed, so it would not hold a login item. Nothing has been removed."

printf 'install: quitting any running copy\n'
pkill -x SeatGauge || true

rm -rf "$DEST"
mkdir -p "$APPLICATIONS"
ditto "$CLEAN" "$DEST"
# dist/ is emptied of the copy it was built from, so Spotlight finds one copy.
rm -rf "$APP"

mkdir -p "$BIN"
[ -L "$LINK" ] || ln -s "$DEST/$HELPER" "$LINK"
printf 'install: %s\n' "$LINK"
on_path=""
IFS=: read -r -a dirs <<<"$PATH"
for dir in "${dirs[@]}"; do
  if [ "${dir%/}" = "${BIN%/}" ]; then on_path=1; fi
done
[ -n "$on_path" ] ||
  printf 'install: %s is not on your PATH, so typing seatgauge-cli will not find it. Add the folder to PATH in your shell profile, or run %s by its full path.\n' "$BIN" "$LINK"

open "$DEST"
printf 'install: %s\n' "$DEST"
printf 'install: Next: the first launch. Seat Gauge has opened and looks for the seats on this Mac.\n'
