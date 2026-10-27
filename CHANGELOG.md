# Changelog

## 0.2.0 - 27 October 2026

The first release under AGPL-3.0-only. Built from source with `make install`, as before; there is no prebuilt download.

- **Licence.** From 0.2.0, Seat Gauge is under the GNU Affero General Public License, version 3 only (AGPL-3.0-only). Version 0.1.0 and earlier were released under the MIT licence and remain available under it to anyone who obtains a copy; the MIT text is kept in `NOTICE`. Contributions are accepted under AGPL-3.0-only. `Package.swift` names the licence by its SPDX id. The fonts stay under the SIL Open Font License, and provider marks stay excluded.
- **A smaller session log.** A closed session stays in `log.json` for 24 hours after it closes (was 7 days), then is deleted from `log.json` and the app's private store alike, so the first pass after updating deletes every closed session older than that for good. Open sessions are never dropped. Closed sessions are trimmed to a budget of 2,000 rows and 2,000,000 bytes for the whole file, shared evenly by the machines in `seats.json`, and each machine keeps its open sessions first, then its newest closed ones. A machine's private ledger and checkpoint drop a session only by age or by that whole budget, so a second app with a different list of machines can't delete rows the first one shows. The oversized ledger copy 0.1.0 could leave behind is deleted.
- **A slimmer checkpoint.** The private checkpoint that lets the Log tab pick up where it stopped reading each transcript kept every message it had seen, reaching 24 MB rewritten every 30 seconds. It now keeps a short digest of each counted message and only what each transcript needs to resume. The first pass after updating rewrites it in the new form.
- **Repository on Log rows.** Each `log.json` row gains `repository`, the GitHub `owner/name` of the folder the session works in, as its `origin` remote spells it, or null when there is none. Only the two names leave the machine, never the remote's URL, a user name or a path. A row from an older probe has no `repository` key, so a reader can tell "none" from "never looked". Branch and repository now come from the folder the agent works in, including a Codex session started with `-C` or `--cd`, whose branch was missed before.
- **The Log probe leaves `/Volumes` alone.** It runs no git in a folder on a mounted volume, or in one whose repository points into `/Volumes`, so git never opens an external drive on its behalf.
- **Session labels from tabs.** A Log row goes by its pane's tab name when the tab was named, so lanes that share one herdr workspace each read as their own repo, section and seat. A workspace that holds one lane reads as before.
- **Folders worth clearing.** `machines.json` names each machine's biggest caches and build output beside `free_gb`, with how to clear each, sized every 15 minutes at background priority. Seat Gauge never deletes them.
- **`machines.json` on every machine.** The app copies `machines.json` once a minute to each other Mac on the LOAD tab, at the same path there, so an agent on any listed machine reads the same file. A Mac that runs its own Seat Gauge keeps its own file.
- **About Seat Gauge.** The app menu opens with About Seat Gauge, which shows the version.
- **`spend.csv` keeps working with odd model names.** A model name with a comma or a line break in it used to break `spend.csv`, after which every roll-up wrote nothing. Such text is now written with a space in its place.
- **Safer recordings.** `seatgauge-cli record` redacts more before anything reaches disk: key and PIN words in more spacings, cases and spellings (look-alike letters included), more kinds of labelled secret, more spellings of home folders and Mac names, and any text with percent-encoding in it. Some names can still get through (#162), so read a recording before you share it.
- **Screenshots in the README.** A short section near the top shows each tab, a narrow window and the light appearance, all drawn from made-up data by `make shots`.
- **For contributors.** The unfiltered `scripts/check.sh` runs the suites that can share the machine side by side, then the rest one at a time, which takes about a third less time than running every case in turn. A failed step prints each failed case's own line, and the tests that failed now and then under load are steady.

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
