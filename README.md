# Seat Gauge

A small always-visible Mac window that shows, for each paid AI subscription login you run (a seat), how much of its 5-hour and weekly windows is used and when each one resets. It counts down to every reset and marks the seat with the most headroom as the best one to work on next. A second tab shows spend per account, rolled up from the local Claude Code transcripts and Codex rollouts.

It reads Claude seats through the `claude` CLI and ChatGPT seats through the `codex` CLI, the same way you would. It never reads the Keychain and never refreshes a token.

Version 0.1.0 is source only: you build it on your own Mac with `make install`. There is no prebuilt download yet. A signed and notarised download may come in a later release.

## Quick start

```sh
git clone https://github.com/LaunchAstro/seat-gauge.git
cd seat-gauge
make install
```

`make install` builds the app, copies it to `/Applications`, links `seatgauge-cli` into `~/.local/bin` and opens the app. If it says `~/.local/bin` is not on your `PATH`, add it in your shell's profile so `seatgauge-cli` runs by name. On first launch the window shows one Claude seat, `claude`, signed out, and a Codex seat if the `codex` CLI is already signed in. Click the `claude` card to sign it in: Terminal opens, you sign in to your Claude account in the browser and paste the code it shows. To add more seats, right-click the window, choose "Reveal config" and edit `seats.json` (see [Add a seat](#add-a-seat)).

## Requirements

- To run: macOS 14 or later.
- To build: macOS 15.6 or later, with the Xcode Command Line Tools that bring Swift 6.2 or later (`xcode-select --install`). Xcode itself is not needed. Swift 6.2 first came with Xcode 26 and its tools, and Apple's Xcode system requirements list macOS 15.6 as the minimum for Xcode 26 (and macOS 26.2 from Xcode 26.4). Since 0.1.0 is built from source, macOS 15.6 is the floor in practice.
- The `claude` CLI for Claude seats, the `codex` CLI for a Codex seat. The app finds each wherever your login shell does. It asks the shell for its `PATH` once per launch, then also looks in the usual install folders (Homebrew on Apple silicon or Intel, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`, `~/.npm-global/bin`, volta, bun and nvm). Those folders are all it has when the shell takes longer than 3 seconds or gives no answer.

## Build and install

```sh
make build      # debug build of the app and seatgauge-cli
make test       # the test suite, under a scratch home
make app        # build dist/Seat Gauge.app with the .dev bundle id, without opening it
make run        # make app, then open it
make check      # the gate: build, tests and privacy scan
make clean      # remove .build and dist
make install    # release build, signed ad hoc, copied to /Applications, CLI linked into ~/.local/bin
```

`make run` builds `com.launchastro.seatgauge.dev`, which keeps its own settings and data, so it never touches an installed copy. `make install` builds `com.launchastro.seatgauge` and leaves exactly one copy on the machine, because the login item follows whichever copy registered it.

`make install` works from a checkout in any folder, iCloud Drive included, and needs no sudo. It also links `seatgauge-cli` into `~/.local/bin`, pointing at the copy inside the installed app, and says so if that folder is not on your `PATH`. It never replaces a `seatgauge-cli` it did not put there: it stops and asks you to move that file first. When it finishes it opens the app, and the next step is the first launch.

The app is signed ad hoc (ADR 0002), so macOS treats every `make install` as a new app. The first time the new copy's Log tab reads a session working in your Desktop, Documents or Downloads folder, macOS asks whether Seat Gauge may open files there, and it asks again after each reinstall. Until you answer, the Log tab shows this Mac's line as a folder-access problem: the probe "did not answer" in time, or git "could not read a session's folder", because macOS holds each read in that folder while its prompt is open. Answer the prompt, or allow Seat Gauge in System Settings > Privacy & Security > Files and Folders, and the line clears on the next pass, within 30 seconds. If you choose Don't Allow, sessions there show no branch and everything else still works.

### What running it does

- **It starts at login.** Run from `/Applications`, the app adds itself to System Settings > General > Login Items on every launch. To stop that, untick "Launch at login" in the window's right-click menu or in Settings; the app remembers and leaves it off. A copy run from anywhere else, such as a `make run` build, never adds itself.
- **It checks your seats for free.** The app reads a Claude seat with its own login by starting `claude -p` and asking it for usage, with no model turn, so the check costs nothing. A Codex poll asks `codex app-server` for its rate limits and runs no model turn either. The default poll is every 5 minutes.
- **A token seat is read only when you sync it.** A seat that signs in with a token reports its windows only during a model turn, so reading it runs one short Haiku turn on that seat's subscription, which counts against its 5-hour and weekly windows like any other. The scheduled poll skips token seats; the app reads them only when you sync that seat or sync all.
- **It reads your login files.** For each seat it reads the plan tier, or the organisation type beside it, from its login (`.claude.json` for Claude, the plan claim in `auth.json` for Codex), and one account id from each Claude login, to tell which seat the main login is (ADR 0005). It keeps these in memory and writes none of them. A token seat's OAuth token is read from its file and handed only to that seat's `claude`.
- **It reads your transcripts.** The Spend tab rolls up the Claude Code transcripts under each seat's profile and the Codex rollouts under `~/.codex/sessions`, and writes the totals to `spend.csv` in its own folder.
- **It runs your open command only when you click.** A seat's `open` command runs when you click its card's mark or name, never on a poll.
- **It fetches two icons.** The app fetches each provider's favicon once, to show beside the provider's name, and caches it. If a fetch fails, the app tries again at the next launch. The request carries no cookies and no other data, and sends Safari's own User-Agent rather than one that names Seat Gauge. It reads at most 1 MB of icon, follows redirects only to the provider's own domains, and refuses an icon too large to draw.

`seatgauge-cli watch` and `seatgauge-cli spend` act on the same live data as the app. `watch` polls your real seats (token seats are skipped, as in the app's scheduled poll), and `spend` rolls up your real transcripts. Both write to the installed app's folder, `~/Library/Application Support/com.launchastro.seatgauge/`, not the `.dev` one.

## Uninstall

1. Right-click the window, untick "Launch at login", then choose Quit.
2. Move `/Applications/Seat Gauge.app` to the Trash. If you built with `make run`, also delete `dist/` in your clone.
3. Remove the command line link: `rm ~/.local/bin/seatgauge-cli`.
4. Remove its settings, readings and spend history: `~/Library/Application Support/com.launchastro.seatgauge/`, and `~/Library/Application Support/com.launchastro.seatgauge.dev/` if you ran `make run`. Then `defaults delete com.launchastro.seatgauge` (and `com.launchastro.seatgauge.dev`), which holds the window's place.
5. Seat logins the app made live in `~/.seat-gauge/profiles/`, one folder per seat, each signed in to a Claude account. Keep any folder you still use outside Seat Gauge. For each one you don't, sign it out first, so its login goes too: `env -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$HOME/.seat-gauge/profiles/<seat>" claude auth logout`, then delete `~/.seat-gauge/profiles/<seat>`. When no folder is left, `rmdir ~/.seat-gauge/profiles ~/.seat-gauge` removes the rest; it refuses while anything is still inside.
6. If you added a machine to the LOAD tab: its ssh connection closes within two minutes of Quit and removes its own socket, `~/.ssh/seatgauge-<hash>`. To clear any left behind, removing sockets only and never a file such as a key: `find ~/.ssh -maxdepth 1 -name 'seatgauge-*' -type s -delete`. On that machine, `rm ~/.local/libexec/seatgauge-log-probe` if you installed the Log helper there.

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

Every Claude seat needs its own `profile` directory, so no card reads whatever `~/.claude` happens to be signed into. The app refuses a Claude seat without one and gives the reason in the title bar. It also refuses a profile that resolves to `~` or `~/.claude`, two seats on one directory, and a Claude seat named `default` or `codex` (spend history keeps those two names). Any other path works, and the Spend tab files the seat's spend under its id. Every seat's `id` is a plain id, the rule first launch uses: a lowercase letter or digit, then lowercase letters, digits, `-` or `_`. The app refuses any other id, since the id names files and fills a column of `spend.csv`.

### Signing a Claude seat in

A seat with `"login": "own"` has its own login, and reads the 5-hour, weekly and Fable windows plus its exact plan. In the app, a seat that is not logged in says "signed out" on its card, and a click on that card (anywhere but its × and the chart's range and measure words), on its name or on Sign in (on the card and on its hover view) starts the sign-in: it opens Terminal running the command below for that seat, where you paste the code the sign-in page shows, and the card reads the seat again once that login ends. From a terminal, sign it in by its id:

```sh
seatgauge-cli login claude
```

This runs `claude auth login` under the seat's own profile. If the profile is not there yet, it creates it, readable by you alone. It prints a link. Open it in any browser, sign in to the account this seat is for, and paste the code the page shows. `claude auth status` then says whether the seat is signed in. The app's Sign in runs this same command. `--email <address>` fills the address in on the sign-in page. The code goes to `claude` and nowhere else, so it is never saved or logged, and the terminal does not show it as you paste it. The command refuses a Codex seat, a token seat, an unknown id, or a profile that is `~`, `~/.claude` or another seat's, before anything runs.

Token seats are optional, and nobody needs one to get started. If a seat should sign in with an OAuth token instead, leave `login` out and give `token` the path of a file that holds the token, such as `"token": "~/tokens/work.token"`. The app hands it only to that seat's `claude`. A seat with neither `login` nor `token` reads its own profile, as `"login": "own"` does: no token file is ever picked up by the seat's name. A token seat shows 5h and 7d only, because no token reports Fable or the exact plan.

### Opening a seat from its card

Give a seat an `open` command and a click on its card's mark or name runs it, so a fresh session starts on that seat already signed in. It is a list of words, run with no shell, and a `~` at the start of the first word is your home:

```json5
{ "id": "work", "label": "Work", "kind": "claude", "profile": "~/.seat-gauge/profiles/work", "login": "own",
  "open": ["~/bin/open-seat", "work"] },
```

The app opens no terminal of its own. The command decides what opens, such as a new terminal window on the seat's profile. It runs with `HOME`, `USER`, `LANG` and a standard `PATH` (Homebrew, `~/.local/bin` and the system folders), and none of the keys the app was launched with. A command that will not start, or exits with a failure within a few seconds, says so in the title bar. A seat without `open` has no click. `~/bin/open-seat` here stands for a script of your own; Seat Gauge ships none.

### The plan on a card

The plan comes from three places, in this order:

1. The tier in the seat's own login file, so a switch between Max 5x and Max 20x shows up by itself. When the tier names no plan, it takes the organisation type beside it instead, which is how a Pro login says Pro.
2. The `plan` you write in `seats.json`.
3. The plan the usage reply names, which for Claude is only `max`.

With none of the three the card shows no plan. It never guesses "free". `seatgauge-cli read` prints each seat's plan beside its reading.

## The command line

`seatgauge-cli` runs the same core without the window, and `seatgauge-cli --version` prints its version:

```sh
seatgauge-cli read            # read every seat once and print it
seatgauge-cli watch           # run the poll loop headless
seatgauge-cli spend           # roll up spend once and say what it found
seatgauge-cli record claude   # poll one seat, write what the parsers read of its reply to .scratch/recordings/ under the current folder
seatgauge-cli login claude    # sign one seat in under its own profile
```

`make install` links `seatgauge-cli` into `~/.local/bin`, and these commands act on the installed app's `seats.json`. The CLI has no bundle of its own, so it always reads the installed app's folder, even when you run it from a clone. To use one against a `make run` build, run it from the clone with `swift run seatgauge-cli` and pass that build's file as the last argument, such as `swift run seatgauge-cli login claude ~/Library/Application\ Support/com.launchastro.seatgauge.dev/seats.json`. `read`, `record`, `login` and `machines` take that argument; `watch`, `spend` and `machines add` work only on the installed app's file.

`record` keeps only the fields the parsers read of what the seat printed, takes credentials, account ids, emails and home paths out of those, and writes them to `.scratch/recordings/<seat>-<date>.jsonl`, readable by you alone. Git ignores that folder. It is still your real usage, so never commit it. The fixtures in the repository are hand-written; use a recording to see the shape, then write a synthetic transcript.

## For agents

After every poll or sync the app writes `headroom.json` beside `readings.json` in its folder, `~/Library/Application Support/com.launchastro.seatgauge/` (the `.dev` build keeps its own). Reading it runs no CLI and touches no seat, so it costs nothing. It holds what the cards show and nothing more.

- `updated`: when the file was written.
- `seats`: one object per seat in `seats.json` order, with `id`, `kind` (`claude` or `codex`), `plan` as the card shows it (or `null`), `stale` and `read_at`.
- `stale` is true when the seat's last read failed, it has never been read, or its figures are two poll intervals old or more. `read_at` is when those figures were taken, or `null` when there are none.
- `five_hour`, `weekly` and `fable`, for each window the seat has: `used` and `left` in percent (they add up to 100) and `resets`. A dormant or never-read seat has no windows. A Claude seat whose 5-hour window nobody has started yet has it as `used` 0, `left` 100 and `resets` `null`, where `null` means not started.

Dates are ISO 8601 with the local offset. The file names no single seat to use, so the reader spreads its work across the seats with room rather than sending it all to one.

The Log tab needs herdr, a terminal workspace manager for coding agents, on each machine it reads; without it the tab stays empty. It publishes one row per observed agent session to `log.json`, with metadata, times and token totals, from each configured machine. See [Session log](docs/session-log.md) for the schema, the freshness rules and how to install the remote helper.

Beside it, `machines.json` holds each machine's load, read every 5 seconds: this Mac, and any other added as below. The panel shows the same figures on its LOAD tab, and hovering a machine card draws its CPU and memory over the last ten minutes.

- `machines`: one object per machine, with `id`, `label`, `reachable`, `stale`, `problem` (why the last read failed, or `null`) and `read_at`.
- `room`: `free`, `busy` or `full`, and `why`, the lines that set it (empty when free). Busy from 60 percent CPU or memory over 30 seconds, a load of 2 per core, or under 25 GB of disk left; full from 85 percent, 3 per core, or under 10 GB.
- `cpu`: `used`, the average over the last 30 seconds, and `now`, the last one-second sample; `trend`, `rising`, `steady` or `falling` against the 30 seconds before (`null` until there is a minute of reads); `load` averages over 1, 5 and 15 minutes, `cores` and `load_per_core`. Load counts the tasks running or waiting for a core, so a load above the core count means work is queueing.
- `ram`: `used` (30-second average, by macOS memory pressure), `now`, `trend` and `total_gb`.
- `disk`: `used` percent, `free_gb`, and `change_10m_gb`, the space gained or lost over the last ten minutes (negative is filling).
- `agents`: the agents herdr runs on that machine, as `working`, `blocked` (waiting on a person), `idle` and `total`, or `null` when the machine has no herdr (the terminal workspace manager above). Agents outside herdr are not counted.

### Add a machine

Any Mac you can reach over ssh with a key:

1. On that Mac, turn on System Settings > General > Sharing > Remote Login.
2. On this one, give it your key: `ssh-copy-id studio.local` (its name or address), and check `ssh studio.local true` returns with no password prompt.
3. Run `seatgauge-cli machines add studio.local Studio`. It reads the machine once to prove it answers, then adds it to `seats.json`; nothing is written if it does not answer. The LOAD tab shows it within a minute.

Nothing is installed on the other Mac. The gauge keeps one ssh connection to it open between reads (its socket is `~/.ssh/seatgauge-*`). Over that connection it also copies `machines.json` to the other Mac once a minute, as below.

`seatgauge-cli machines` reads every machine once and prints the same shape.

`skills/seat-gauge/` is a ready-made agent skill that reads this file. Copy or link the folder into your agent's skills folder, such as `~/.claude/skills/` for Claude Code or `~/.agents/skills/` for Codex, and an agent asked which seat has room reads the file instead of spending a seat to check.

### Read it on another machine

The app copies `machines.json` to each other listed Mac that answered its last read, at most once a minute, into the same folder there: `~/Library/Application Support/com.launchastro.seatgauge/machines.json`. An agent on that Mac reads the same path as one on this Mac, and the skill's command works unchanged. The copy goes over the connection the gauge already keeps open, runs only `sh` there, writes that one file (readable by its owner alone) and nothing else, and replaces it in one rename, so a reader never sees half a file.

- Check `updated`. A copy goes out at most once a minute and only after a read, so it can be a minute plus one read interval old (65 seconds by default). Twice that or older (over two minutes by default) means the copies have stopped: the app has quit, or the machine went unreachable.
- A Mac with its own `seats.json` in that folder runs its own app, which writes its own `machines.json`, so it gets no copy.
- `headroom.json` and `log.json` are not copied; they stay on the Mac running the app.

### Beside session tracing

If you also trace agent sessions with a tool such as Langfuse, an open source tracer for LLM apps, don't add its token counts to Seat Gauge's: both read the same local transcripts. See `docs/adr/0006-seat-gauge-and-langfuse-answer-different-questions.md`.

## Known limits

- macOS only, and built from source: there is no signed download yet.
- Spend is list-price dollars worked out from local transcripts. It is a floor and not your bill: a flat plan is not charged per token, and some billed calls are never written to a transcript.
- A token seat shows the 5-hour and weekly windows only, and reading it uses one short Haiku turn.
- The Log tab and the agent counts on the LOAD tab need herdr.
- Seats are read through the `claude` and `codex` CLIs, so a CLI update that changes what they print can break a reading until Seat Gauge catches up.

## Working on it

`AGENTS.md` says where things live and how to change them. `CONTEXT.md` is the glossary, and `docs/adr/` holds the decisions. Before you push, run `scripts/check.sh` with the tests for what you changed.

## Licence

From the release after 0.1.0, the code is under the GNU Affero General Public License, version 3 only (AGPL-3.0-only), in `LICENSE`. Version 0.1.0 and earlier were released under the MIT licence and remain available under it to anyone who obtains a copy; its text is in `NOTICE`. The bundled fonts (Funnel Display, Funnel Sans, Chivo Mono) are under the SIL Open Font License, in `Resources/Fonts/OFL.txt`.

Claude and Anthropic are trademarks of Anthropic. ChatGPT, Codex and OpenAI are trademarks of OpenAI. Seat Gauge is not made or endorsed by either company. The app shows each provider's own favicon, fetched from the provider's site at runtime, only to say which service a seat belongs to. No provider mark ships in this repository, and none is covered by either licence. See `NOTICE`.
