# Changelog

## Unreleased

- **Licence.** Seat Gauge is under the GNU Affero General Public License, version 3 only (AGPL-3.0-only), from the next release. Version 0.1.0 and earlier were released under the MIT licence and stay available under it for anyone who received them; the MIT text is kept in `NOTICE`. Contributions are accepted under AGPL-3.0-only. The fonts stay under the SIL Open Font License, and provider marks stay excluded.

## 0.1.0 - 26 October 2026

The first public release. Built from source with `make install`; there is no prebuilt download.

- **Seat cards.** One card per subscription login (a seat), Claude through the `claude` CLI and ChatGPT through the `codex` CLI. Each shows how much of its 5-hour and weekly windows is used, the Fable window where a Claude login has it, the plan, and a countdown to each reset. The seat with the most headroom is marked as the best one to work on next, and a notification comes as a seat's weekly reset nears. Reading a seat with its own login runs no model turn, so it costs nothing.
- **Sign in from the card.** A signed-out Claude seat signs in from a click on its card, in Terminal, under its own profile in `~/.seat-gauge/profiles`. First launch finds the profiles there and a signed-in Codex, and writes `seats.json` once.
- **Spend tab.** Spend per account over time, in tokens or list-price dollars, rolled up from the local Claude Code transcripts and Codex rollouts into `spend.csv`.
- **Load tab.** CPU, memory, disk and agents working for this Mac and any other Mac reached over ssh, with a free, busy or full verdict.
- **Log tab.** One row per agent session run under herdr, with its seat, model and token totals, on each configured machine.
- **Files for agents.** `headroom.json`, `machines.json` and `log.json` hold what the window shows, free to read. `skills/seat-gauge/` is a ready-made agent skill that reads them.
- **`seatgauge-cli`.** The same core without the window: read, watch, spend, record, login, machines and `--version`.
- **Launch at login** from `/Applications`, which you can turn off in the right-click menu or Settings, plus appearance and text size settings.

Needs macOS 14 or later to run, and macOS 15.6 or later with the Command Line Tools for Swift 6.2 to build.
