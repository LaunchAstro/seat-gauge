#!/usr/bin/env bash
# Run one command under a scratch home, so a `swift test` cannot reach the
# developer's own. `HOME` and `CFFIXED_USER_HOME` point at a folder
# made for this run and removed when it ends, which is where
# `NSHomeDirectory()` and Application Support then resolve. Defaults are not
# moved: cfprefsd picks the plist by user account and bundle id, whatever the
# home says, so a test process's defaults stay in the test runner's own domain.
#
#   scripts/scratch-home.sh swift test --no-parallel
set -u
[ $# -gt 0 ] || { printf 'scratch-home: give the command to run.\n' >&2; exit 2; }
tmp="${TMPDIR:-/tmp}"
scratch="$(mktemp -d "${tmp%/}/seat-gauge-home.XXXXXX")" ||
  { printf 'scratch-home: could not make a scratch home, so nothing ran.\n' >&2; exit 2; }
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT TERM
HOME="$scratch" CFFIXED_USER_HOME="$scratch" "$@"
