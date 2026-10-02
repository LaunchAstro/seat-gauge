# AGENTS.md

Start here. This file says where things live, how to check a change, and the rules that are easy to break. `CONTEXT.md` has the words, `docs/adr/` has the decisions behind them.

## Layout

Three SwiftPM targets, Command Line Tools only (no Xcode project).

- `Sources/SeatGaugeCore/` imports Foundation only, so every type in it is testable without a screen. All the rules live here.
- `Sources/SeatGauge/` is the Mac app: AppKit window, SwiftUI cards, menus, login item, notifications. It turns core values into pixels and holds no rules of its own.
- `Sources/seatgauge-cli/` drives the core headless: `read`, `record`, `watch`, `spend`, `state`, `attribute`, `import-codex`, `login`.
- `Tests/Support/` is a library both test targets share: `ScriptedRunner` and the `Fixture` loader. Nothing in it ships.

### Core modules and their one job

| File | Job |
| --- | --- |
| `Domain.swift` | `Seat`, `Window`, `Reading`, `SeatState`, `Snapshot` (with the best-seat rule) and `PlanText` (which plan a card shows). |
| `Config.swift` | Reads and validates `seats.json`, seeds it on first launch from what `SeatDiscovery` finds, never over an existing file, and re-reads it when it changes. |
| `SeatDiscovery.swift` | What first launch finds, by name and existence only: each profile under the app's profile root `~/.seat-gauge/profiles` (`SeatDiscovery.profileFolder`), and a signed-in Codex. With no profile, one fresh `claude` seat there. |
| `AppPaths.swift` | The bundle ID and the folders the app keeps: Application Support and the primer directories its own polls run in. |
| `Fetchers.swift` | The `SeatFetching` seam, and one fetcher per seat kind that runs the seat's CLI. |
| `ChildEnvironment.swift` | The allowlist of variables each CLI child gets, proxy settings included. Nothing else the app inherited reaches it. |
| `ProcessRunner.swift` | The `ProcessRunning` seam: `RealProcessRunner` spawns the CLI. In tests, `ScriptedRunner` (`Tests/Support/`) replays fixture lines instead. |
| `SearchPath.swift` | Where a CLI child looks for `claude` and `codex`: the login shell's `PATH`, asked once with a timeout, then a fixed list of the usual installs. Only `PATH` comes from the shell, and only the app and `seatgauge-cli` ask it (`SearchPath.loginShell`); a runner's default is the fixed list. |
| `ClaudeUsageParser.swift`, `ClaudeRateLimitEventParser.swift`, `CodexRateLimitsParser.swift` | Turn one CLI transcript into windows. Each wire format is known in exactly one parser. |
| `AccountPlan.swift` | Reads the exact plan tier from a seat's own login file. |
| `ProviderMark.swift` | `MarkCache`: fetches each provider's favicon once, when none is cached, and keeps it in Application Support. |
| `SeatLogin.swift` | Signs one seat in: `claude auth login` on a pseudo-terminal under the seat's own profile, the link out, the pasted code in, and `claude auth status` as the proof. Every front end signs in through it. |
| `SeatToken.swift` | Where a token seat's token file is, read at fetch time and handed to one child process. |
| `RefreshService.swift`, `Poller.swift`, `GaugeStore.swift` | Fetch the seats one after another, loop on the poll interval, and keep the last readings on disk. |
| `Pace.swift`, `Alerts.swift` | The pace verdict and countdown text, and when a reset alert is due. |
| `SpendCoordinator.swift` | The one writer of `spend.csv`. Takes a file lock, runs both collectors, adds up their `SpendCollection`s, merges and writes once. |
| `ClaudeCollector.swift`, `CodexCollector.swift`, `CodexRollout.swift` | Walk Claude transcripts and Codex rollouts into hourly spend cells. |
| `Spend.swift`, `SpendCSV.swift`, `SpendRecord.swift` | Token counts, the rate card, and the CSV record: its day and hour columns and its sealing rule. |
| `Attribution*.swift`, `IdentityObserver.swift`, `SpendAttribution.swift` | Which seat the default `~/.claude` login was at each hour, so its spend lands on the right account. |
| `SpendChart.swift`, `SeatHistory.swift` | Series for the Spend tab and a card's history chart. |
| `State.swift` | `state.json`: roll-up watermark and panel choices, under a file lock. |

In the app, `PanelModel.swift` builds what each card shows from a `Snapshot`, `PanelRoot.swift` holds `GaugeMirror` (the main-actor copy of the latest state), `WindowController.swift` and `PanelHeight.swift` size the window, `SignIn.swift` is a card's Sign in (the browser, the code prompt and the proof around `SeatLogin`), and `main.swift` wires it all together.

## Check a change

```sh
scripts/check.sh
```

The gate. It builds, runs the tests under a scratch home so no test touches your real Application Support folder, and fails on an email address or a real-looking home path in the tree. `swift build` and `make test` are the parts. Run it once before each push, not after every edit.

The two tests that launch the real `claude` and `codex` run only under `SEATGAUGE_INTEGRATION=1` (see `CONTRIBUTING.md`).

The test suite uses Swift Testing (`@Test`), which ships with the Command Line Tools. Every `swift` command needs the framework flags in the `Makefile`, so prefer `make build` and `make test` to bare `swift`.

## Add a seat kind

A new provider, beside `claude` and `codex`. The compiler flags every exhaustive `switch` you miss.

1. Add a case to `SeatKind` in `Domain.swift`.
2. Accept its `kind` string in `ConfigLoader.decode` (`Config.swift`), with a one-sentence `ConfigProblem` for anything it refuses.
3. Write a parser that turns the CLI's output lines into a `FetchOutcome`. Look at what a real seat prints with `seatgauge-cli record <seat>`, then hand-write a synthetic fixture in that shape (invented timestamps, round numbers) and test the parser against it. Never commit the recording.
4. Write a `SeatFetching` adapter in `Fetchers.swift` that runs the CLI through `ProcessRunning`, and return it from `seatFetcher(for:)`. The app and the CLI both build fetchers there.
5. Add a `Provider` case in `Domain.swift` with its `name` and the `site` whose icon is its mark. `MarkCache` (`ProviderMark.swift`) fetches that icon at runtime; no provider image goes in the repository.
6. If the provider keeps usage logs, add a collector beside `ClaudeCollector` and `CodexCollector` that returns a `SpendCollection`, and add it up in `SpendCoordinator`.

## Add a window

A new quota bucket, beside 5-hour, weekly and Fable.

1. Add a case to the end of `WindowKind` in `Domain.swift`. `readings.json` stores the raw value, so never reorder or insert.
2. Map it in the parser that reads it, with its length.
3. Give it a short name in `WindowKind.shortName` (`PanelModel.swift`) and in `describe(_:now:)` in `seatgauge-cli/main.swift`.

The best-seat rule, pace and alerts read every window already.

## Rules

- **Seats are read through their own CLIs.** The gauge runs `claude` or `codex` headless and parses what they print. It never calls a usage endpoint, never reads the Keychain, and never refreshes a token. The only exceptions are four named fields read from login files, for identity and plan, listed in ADR 0005. See ADR 0001 before you reach for an API.
- **No secrets in the repo.** Tokens, OAuth credentials, account ids and email addresses never go into code, fixtures, tests, docs or commits. Fixtures are hand-written. A recording from `seatgauge-cli record` stays on your machine.
- **No personal data in the tree.** Seat names in examples and tests are neutral (`personal`, `work`, `codex`). No home paths.
- **Every Claude seat has its own profile directory.** Never `~` or `~/.claude`, and never one another seat uses. `seats.json` refuses each at load time, so no card reads whatever the main login is signed into. First launch looks for profiles only under `~/.seat-gauge/profiles`, never under anyone's own naming, and seeds every Claude seat with `"login": "own"`, so no seeded seat takes a token.
- **Each CLI child gets a built environment.** `ChildEnvironment.swift` allowlists what reaches `claude` and `codex`; an inherited API key never does.
- **`spend.csv` is a record, not a cache.** Sealed rows are never rewritten, and only `SpendCoordinator` writes the file (ADR 0004).
- **Tests never touch the real home.** They run under `scripts/scratch-home.sh`. A dev build uses the `.dev` bundle id for the same reason.

## Writing

Australian English, sentence-case headings, no em dashes. Comments say why, not what.
