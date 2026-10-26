#!/usr/bin/env bash
# Put the built app in /Applications, replacing only a copy of Seat Gauge
# there, and link `seatgauge-cli` into `~/.local/bin`.
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
# The new copy is staged and checked beside the old one before anything is
# quit or removed, then swapped in by renames on the same volume. A copy that
# fails partway, such as on a full disk, leaves the old app where it was.
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
# Only a copy of this app is ever replaced: an unrelated app of the same name,
# or a link, is the user's to move.
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  [ ! -L "$DEST" ] && [ -d "$DEST" ] &&
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null)" = "$ID" ] ||
    refuse "$DEST is there and is not Seat Gauge ($ID), so this script will not replace it. Move it away, then install again. Nothing has been removed."
fi
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$DEST/$HELPER" ] ||
    refuse "$LINK is already there, and this script did not put it there. Move it away, then install again. Nothing has been removed."
fi
# The folder, or the nearest part of its path that is there, has to be a folder
# this script can write in, or the link would fail after the app was replaced.
up="$BIN"
while [ ! -e "$up" ] && [ ! -L "$up" ]; do up="$(dirname "$up")"; done
[ -d "$up" ] && [ -w "$up" ] ||
  refuse "$BIN cannot take seatgauge-cli: $up is not a folder you can write in. Nothing has been removed."
# mdfind is the only way another copy is found, and an index that is off
# answers with silence rather than with an error. That silence would read as
# no other copy, so it is a refusal. Recent macOS reports / as read-only, and
# that index still answers mdfind, so it counts as on. The status has to be
# exactly one of those two lines; anything else refuses. Straight after a
# build, while Spotlight is busy with the new files, mdutil can answer
# something else for a moment, so the status is asked a few times, a second
# apart, before an answer that stays wrong is a refusal.
indexed=""
for _ in 1 2 3 4 5; do
  status="$(mdutil -s / 2>/dev/null |
    sed -e '/^\/:$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' || true)"
  case "$status" in
    'Indexing enabled.' | 'Index is read-only.') indexed=1; break ;;
  esac
  sleep 1
done
[ -n "$indexed" ] ||
  refuse "Spotlight indexing is off on /, so other copies of the app cannot be found."

SOURCE="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
others=""
while IFS= read -r copy; do
  [ -n "$copy" ] || continue
  # The copy being installed from and the one being replaced are expected.
  [ "$copy" = "$SOURCE" ] || [ "$copy" = "$DEST" ] && continue
  # The index can still list a copy that has since been deleted.
  [ -e "$copy" ] || continue
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

# Staged on the same volume, so the swap below is two renames. The new copy
# sits at the same depth it will be installed at, and `old` holds the copy
# being replaced until the new one is in; the folder is removed at the end
# unless the old copy could not be put back, when it is all that is left.
mkdir -p "$APPLICATIONS"
stage="$(mktemp -d "$APPLICATIONS/.seat-gauge-install.XXXXXX")"
trap 'rm -rf "$scratch"; [ -e "$stage/old" ] || rm -rf "$stage"' EXIT
NEW="$stage/Seat Gauge.app"
ditto "$CLEAN" "$NEW" ||
  refuse "the new copy could not be written in $APPLICATIONS. Nothing has been removed."
codesign --verify --strict "$NEW" >/dev/null 2>&1 ||
  refuse "the new copy in $APPLICATIONS does not pass its signature check. Nothing has been removed."

# Only the installed copy is quit. A `make run` build has its own path and
# keeps running.
printf 'install: quitting the installed copy\n'
pattern="$(printf '%s' "$DEST/Contents/MacOS/SeatGauge" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
pkill -f "^$pattern( |$)" || true

if [ -e "$DEST" ]; then
  mkdir "$stage/old"
  mv "$DEST" "$stage/old/" ||
    refuse "the installed copy could not be moved aside. It is where it was."
fi
if ! mv "$NEW" "$DEST"; then
  [ -e "$stage/old" ] || refuse "the new copy could not be put in place, and there was no copy before it."
  mv "$stage/old/Seat Gauge.app" "$DEST" && rmdir "$stage/old" ||
    refuse "the new copy could not be put in place, and the copy before it is at $stage/old. Move it back to $APPLICATIONS."
  refuse "the new copy could not be put in place. The copy before it is back in $APPLICATIONS."
fi
rm -rf "$stage"
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
