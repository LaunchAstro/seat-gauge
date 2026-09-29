# Contributing to Seat Gauge

Thanks for helping. Seat Gauge builds with the Xcode Command Line Tools alone
(Swift 6.2, macOS 14 or later). You don't need Xcode.

## Build and run

```sh
make build   # debug build
make app     # dist/Seat Gauge.app, under the .dev bundle identifier
make run     # make app, then open it
```

`make app` and `make run` build under the `.dev` identifier, so a build from
your clone keeps its own Application Support folder and defaults and never
touches an installed copy. `make app SEATGAUGE_REAL_ID=1` builds with the real
identifier. `make install` always does, and replaces the copy in
`/Applications`.

## Test

```sh
make test
```

Tests use Swift Testing. `make test` runs them through
`scripts/scratch-home.sh`, which gives the run a fresh `HOME` that is deleted
afterwards, so no test can read or write your own seats, state or logins. The
panel suites share one `GaugeMirror`, so the tests run serially.

Tests that draw the panel run at the ordinary text step, in one appearance and
at one sensible width, unless the test is about that axis. The ordinary step is
`TextScale.normal`, factor 1, the size every number in the code is written at.
Its label reads 85 percent, because the labels count the default step, one up,
as 100 percent.

Two integration tests launch the real `claude` and `codex` binaries, each with
a scratch config that declares an MCP server script, to prove the gauge's
launch starts none. They run only when you ask:

```sh
SEATGAUGE_INTEGRATION=1 make test
```

They need both CLIs on your `PATH`. The scratch home holds no login, so no
model turn runs and nothing is spent. Without the variable, `make test` and the
gate skip them and say why.

### Fixtures

`Tests/Fixtures/` holds hand-written transcripts in the shape each CLI prints:
invented timestamps, round numbers, no real reset times, ids or paths. To
cover a new shape, write a new synthetic line. `seatgauge-cli record <seat>`
shows you what a real seat prints, but its file is your own usage: read it,
then write the fixture by hand rather than committing the recording.

## The gate

```sh
make check   # or scripts/check.sh
```

The gate builds, runs the tests, and scans the tree for anything private: an
email address, a macOS home path, or a Linux home path under anything but the
placeholder names the fixtures use. A pull request needs a green gate. The scan
is a floor. Read your diff for names, places and account details before you
push.

## Pull requests

- One change per pull request, on a branch off `main`.
- Say what changed and why in the description. Link the issue if there is one.
- Add or update a test for any behaviour you change.
- Never commit a token, an OAuth credential, an account email or a real home
  path, including in fixtures. Refer to seats by name.

## Style

- Swift 6 language mode. `SeatGaugeCore` stays Foundation-only so it can be
  tested without a screen; anything that draws lives in `SeatGauge`.
- Match the surrounding code: its naming, its comment density, its idiom.
- Comments and docs in Australian English, sentence-case headings, no em
  dashes.
