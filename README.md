# Seat Gauge

A small always-visible Mac window that shows, for each paid AI subscription login you run (a seat), how much of its 5-hour and weekly windows is used and when each one resets. It counts down to every reset and marks the seat with the most headroom as the best one to work on next. A second tab shows spend per account, rolled up from the local Claude Code transcripts and Codex rollouts.

It reads Claude seats through the `claude` CLI and ChatGPT seats through the `codex` CLI, the same way you would. It never reads the Keychain and never refreshes a token.

## Requirements

- macOS 14 or later.
- Xcode Command Line Tools with Swift 6.2 (`xcode-select --install`). Xcode itself is not needed.
- The `claude` CLI for Claude seats, the `codex` CLI for a Codex seat, both on your `PATH`.

## Build and install

```sh
make build      # debug build of the app and seatgauge-cli
make test       # the test suite, under a scratch home
make run        # build dist/Seat Gauge.app with the .dev bundle id and open it
make install    # release build, signed ad hoc, copied to /Applications
```

`make run` builds `com.launchastro.seatgauge.dev`, which keeps its own settings and data, so it never touches an installed copy. `make install` builds `com.launchastro.seatgauge` and leaves exactly one copy on the machine, because the login item follows whichever copy registered it.

### What running it does

- **It checks your seats for free.** A Claude seat with its own login is read by starting `claude -p` and asking it for usage, with no model turn, so the check costs nothing. A Codex poll asks `codex app-server` for its rate limits and runs no model turn either. The default poll is every 5 minutes.
- **A token seat is read only when you sync it.** A seat that signs in with a token reports its windows only during a model turn, so reading it runs one short Haiku turn on that seat's subscription, which counts against its 5-hour and weekly windows like any other. The scheduled poll skips token seats; they are read when you sync that seat or sync all.
- **It reads your login files.** For each seat it reads the plan tier from its login (`.claude.json` for Claude, the plan claim in `auth.json` for Codex), and one account id from each Claude login, to tell which seat the main login is (ADR 0005). It keeps these in memory and writes none of them. A token seat's OAuth token is read from its file and handed only to that seat's `claude`.
- **It reads your transcripts.** The Spend tab rolls up the Claude Code transcripts under each seat's profile and the Codex rollouts under `~/.codex/sessions`, and writes the totals to `spend.csv` in its own folder.
- **It fetches two icons.** The app fetches each provider's favicon once, to show beside the provider's name, and caches it. A fetch that fails is tried again at the next launch. The request carries no cookies and no other data.

`seatgauge-cli watch` and `seatgauge-cli spend` act on the same live data as the app. `watch` polls your real seats (token seats are skipped, as in the app's scheduled poll), and `spend` rolls up your real transcripts. Both write to the installed app's folder, `~/Library/Application Support/com.launchastro.seatgauge/`, not the `.dev` one.

## Add a seat

The app writes `seats.json` into its own folder on first launch:

- `make run` and `make app`: `~/Library/Application Support/com.launchastro.seatgauge.dev/seats.json`
- `make install`: `~/Library/Application Support/com.launchastro.seatgauge/seats.json`

The surest way to the right one is to right-click the window and choose "Reveal config", which opens the folder of the copy that is running. Edit the file and save; the window re-reads it within a minute.

First launch fills it from what is on the Mac, found by name alone with no login read: each Claude profile folder in `~/.seat-gauge/profiles` named as a seat id (a lowercase letter or digit, then those, `-` or `_`; not `default` or `codex`), then Codex if the `codex` CLI is signed in. With no profile there, it names one new Claude seat, `claude`, and makes its profile folder, `~/.seat-gauge/profiles/claude`; its card says it is not logged in until you sign it in (below). A `seats.json` that is already there is never rewritten. To add a Claude seat, make a folder for it in `~/.seat-gauge/profiles` and add a line:

```json5
{
  "seats": [
    { "id": "personal", "label": "Personal", "kind": "claude", "profile": "~/.seat-gauge/profiles/personal", "login": "own" },
    { "id": "work",     "label": "Work",     "kind": "claude", "profile": "~/.seat-gauge/profiles/work",     "login": "own", "plan": "Max 20x" },
    { "id": "codex",    "label": "Codex",    "kind": "codex" },
  ],
  "pollMinutes": 5,
}
```

Every Claude seat needs its own `profile` directory, so no card reads whatever `~/.claude` happens to be signed into. A Claude seat without one is refused, with the reason in the title bar, and so is a profile that resolves to `~` or `~/.claude`, two seats on one directory, or a Claude seat named `default` or `codex` (spend history keeps those two names). Any other path works, and the Spend tab files the seat's spend under its id.

### Signing a Claude seat in

A seat with `"login": "own"` has its own login, and reads the 5-hour, weekly and Fable windows plus its exact plan. Give a seat its own login in one line, then type `/login`:

```sh
env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$HOME/.seat-gauge/profiles/work" claude
```

Leave `login` out and the seat signs in with an OAuth token instead, read from the file its `token` key names or from `~/.config/claude-seats/<id>.token`. A token seat shows 5h and 7d only, because no token reports Fable or the exact plan.

### The plan on a card

The plan comes from three places, in this order: the tier in the seat's own login file, so a switch between Max 5x and Max 20x shows up by itself; then the `plan` you write in `seats.json`; then the plan the usage reply names, which for Claude is only `max`. With none of the three the card shows no plan. It never guesses "free". `seatgauge-cli read` prints each seat's plan beside its reading.

## The command line

`seatgauge-cli` runs the same core without the window:

```sh
swift run seatgauge-cli read          # read every seat once and print it
swift run seatgauge-cli watch         # run the poll loop headless
swift run seatgauge-cli spend         # roll up spend once and say what it found
swift run seatgauge-cli record work   # poll one seat, write its reply to Tests/Fixtures/
```

`record` writes a local file of what the seat printed, with account ids, tokens and home paths taken out. It is still your real usage, so never commit it as is. The fixtures in the repository are hand-written; use a recording to see the shape, then write a synthetic transcript.

## For agents

After every poll or sync the app writes `headroom.json` beside `readings.json` in its folder, `~/Library/Application Support/com.launchastro.seatgauge/` (the `.dev` build keeps its own). Reading it runs no CLI and touches no seat, so it costs nothing. It holds what the cards show and nothing more.

- `updated`: when the file was written.
- `seats`: one object per seat in `seats.json` order, with `id`, `kind` (`claude` or `codex`), `plan` as the card shows it (or `null`), `stale` and `read_at`.
- `stale` is true when the seat's last read failed, it has never been read, or its figures are older than two poll intervals. `read_at` is when those figures were taken, or `null` when there are none.
- `five_hour`, `weekly` and `fable`, for each window the seat has: `used` and `left` in percent (they add up to 100) and `resets`. A dormant or never-read seat has no windows.

Dates are ISO 8601 with the local offset. The file names no single seat to use, so the reader spreads its work across the seats with room rather than sending it all to one.

## Working on it

`AGENTS.md` says where things live and how to change them. `CONTEXT.md` is the glossary, and `docs/adr/` holds the decisions. Run `scripts/check.sh` before you push.

## Licence

MIT, see `LICENSE`. The bundled fonts (Funnel Display, Funnel Sans, Chivo Mono) are under the SIL Open Font License, in `Resources/Fonts/OFL.txt`.

Claude and Anthropic are trademarks of Anthropic. ChatGPT, Codex and OpenAI are trademarks of OpenAI. Seat Gauge is not made or endorsed by either company. The app shows each provider's own favicon, fetched from the provider's site at runtime, only to say which service a seat belongs to. No provider mark ships in this repository, and none is covered by the MIT licence. See `NOTICE`.
