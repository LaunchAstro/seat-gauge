#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ "$#" -eq 1 ] || { echo 'usage: scripts/install-log-probe.sh <ssh destination>' >&2; exit 2; }
helper='.build/release/seatgauge-cli'
[ -x "$helper" ] || { echo 'Build the release helper with make install first.' >&2; exit 1; }

# The helper runs the same parser at the far end. No transcript crosses SSH.
ssh -T -o BatchMode=yes -o ConnectTimeout=8 -- "$1" '
  set -eu
  umask 077
  mkdir -p "$HOME/.local/libexec"
  target="$HOME/.local/libexec/seatgauge-log-probe"
  cat > "$target.new"
  chmod 700 "$target.new"
  mv "$target.new" "$target"
' < "$helper"
printf 'Log probe installed. The Log tab reads it within 30 seconds.\n'
