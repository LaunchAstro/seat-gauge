#!/usr/bin/env bash
# The gate every pull request passes: the build, the full test run under a
# scratch home, and a privacy scan of the tree. Each step prints one line,
# `check: <step> pass` or `check: <step> FAIL`, and the run exits 1 if any
# step failed.
#
#   scripts/check.sh                   every test: only when the owner asks
#   scripts/check.sh MachineLoadTests  the tests for what the change builds
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# Swift Testing ships with the Command Line Tools and XCTest does not, so every
# swift run points at the tools' frameworks.
CLT="/Library/Developer/CommandLineTools"
SWIFT_FLAGS=(-Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks"
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks"
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib")

failed=0
step() {
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    printf 'check: %s pass\n' "$name"
  else
    printf 'check: %s FAIL\n%s\n' "$name" "$(printf '%s\n' "$out" | tail -n 20)"
    failed=1
  fi
}

# The tree is what a push could publish: tracked files, and untracked ones git
# does not ignore. It fails on an email address, a macOS home path, or a Linux
# home path under a real-looking name, or a token-shaped string (an Anthropic
# key, a GitHub token, a JWT), in any file's text or path. The test fixtures
# may use the placeholder homes `seat`, `example`, `user` and `someone`. A
# fixture that needs a token shape builds it at run time, so the literal is
# not in the source. The patterns are split so this file does not match itself.
privacy() {
  local users email homes tokens hits
  users="/Us""ers/"
  email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'
  tokens='sk-a''nt-[A-Za-z0-9_-]{8,}|(gh''p|gh''o)_[A-Za-z0-9]{16,}|github''_pat_[A-Za-z0-9_]{16,}|ey''J[A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]{8,}[.]'
  homes='while (m{/home/([A-Za-z0-9._-]+)}g) { next if $1 =~ /^(seat|example|user|someone)$/; print; last }'
  hits="$( {
    git grep -n -I -E --untracked -e "$email" -e "$users" -e "$tokens"
    git grep -n -I -E --untracked -e '/home/[A-Za-z0-9._-]+' | perl -ne "$homes"
    git ls-files --cached --others --exclude-standard | grep -E -e "$users"
  } 2>/dev/null )"
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits" | cut -c1-160
  return 1
}

step "swift build" swift build "${SWIFT_FLAGS[@]}"
# Serial, because the panel suites share one `GaugeMirror`.
FILTER=()
[ -n "${1:-}" ] && FILTER=(--filter "$1")
step "swift test" scripts/scratch-home.sh swift test --no-parallel ${FILTER[@]+"${FILTER[@]}"} "${SWIFT_FLAGS[@]}"

step "privacy" privacy

exit "$failed"
