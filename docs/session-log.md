# Session log

The Log tab publishes `log.json` in the app's Application Support folder, beside `machines.json` and `headroom.json`. It polls the configured machines every 30 seconds. `seatgauge-cli log` runs one round and prints the same snapshot.

Each row is keyed by `machine` and `session_id`. It carries workspace and pane, tool, model and effort, repo, section, seat, branch, `started_at`, `closed_at`, status, `as_of`, `stale`, token counts, counts by model, and list-price USD. Workspace labels split from the right as `<repo>-<section>-<seat>`. A label without three parts leaves those fields empty. A model with no known price leaves the price empty.

Start means the first time the probe saw the session working. `done` means a finished turn. Close means the pane disappeared or its agent process exited. A failed machine read keeps its rows, with `stale` set, and says why under `problems`, keyed by machine. A read that answered can still name something it could not read there, such as a folder macOS held. Consumers also compare `as_of` with their clock and reject figures older than 90 seconds, including when the app has quit.

## Remote machines

The SSH machine needs the same version of the CLI helper and herdr at `~/.local/bin/herdr`. After `make install`, run:

```sh
scripts/install-log-probe.sh <ssh destination>
```

This installs only the helper at `~/.local/libexec/seatgauge-log-probe`. It uses the existing SSH login, without a password prompt. Repeat after upgrading the app. A missing helper shows up as a Log problem.

## Folder access on this Mac

The local probe runs inside the app, so macOS asks the app, not a terminal, whether it may open Desktop, Documents or Downloads, where many sessions work. The app is signed ad hoc, so every reinstall asks again. While that prompt is unanswered, macOS holds each read in the folder. The probe gives each `git` branch read 2 seconds; when one is held, it skips `git` for the rest of the pass, keeps the branches it last saw, and reports a folder-access problem for this Mac. A whole pass that runs past 90 seconds on this Mac is reported the same way rather than as a missing helper. Answer the prompt, or allow Seat Gauge in System Settings > Privacy & Security > Files and Folders. Over SSH no prompt appears, so neither case arises on a remote machine.

## Collection and privacy

The probe uses herdr pane and process information, then `lsof -b` on each agent PID. Codex can hold several rollouts, forks included. Each file has one owner and contributes once. Claude can report its session through herdr. Otherwise the probe matches its profile, working folder and file creation time within two minutes of process start. An ambiguous match keeps tokens pending.

The machine-local helper uses the Spend parsers and keeps a byte offset, numeric usage events and running totals for each file. A partial line waits until it is complete. Each Claude message ID counts once. Codex resumes use Spend's first-token ordering, including across read budgets, with a separate baseline for each forked session ID.

Seat Gauge decodes only usage metadata from the log records it needs, and never inspects, keeps or sends message content. The public file contains no transcript paths, process arguments, prompts, or commands. Each machine keeps its pane observations in the private `log-private/observations.jsonl`, with a replaceable `offsets.json` checkpoint beside it. A pass appends a line only for a session that changed; an open one is also written every ten minutes, so a row that goes stale says about when it was last seen, and when another session of the same process is written, so the ledger keeps which of them was seen last. Once the file holds more than four lines per session (and more than 256) it is rewritten as one line per session, the last each one had. A ledger over 64 MB was written before compaction, so the first compaction keeps it beside the new one as `observations-before-compaction-<time>.jsonl`, which nothing reads and you can delete. The directory is owner-only, and the files use mode 600. If you delete the checkpoint, the helper rebuilds token totals from the source logs, while the ledger keeps pane history. Keep the ledger if you want observations to outlast their panes.
