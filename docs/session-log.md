# Session log

The Log tab publishes `log.json` in the app's Application Support folder, beside `machines.json` and `headroom.json`. It polls the configured machines every 30 seconds. `seatgauge-cli log` runs one round and prints the same snapshot.

Each row is keyed by `machine` and `session_id`. It carries workspace and pane, tool, model and effort, repo, section, seat, branch, `started_at`, `closed_at`, status, `as_of`, `stale`, token counts, counts by model, and list-price USD. Workspace labels split from the right as `<repo>-<section>-<seat>`. A label without three parts leaves those fields empty. A model with no known price leaves the price empty.

Start means the first time the probe saw the session working. `done` means a finished turn. Close means the pane disappeared or its agent process exited. A failed machine read keeps its rows, with `stale` set. Consumers also compare `as_of` with their clock and reject figures older than 90 seconds, including when the app has quit.

## Remote machines

The SSH machine needs the same version of the CLI helper and herdr at `~/.local/bin/herdr`. After `make install`, run:

```sh
scripts/install-log-probe.sh <ssh destination>
```

This installs only the helper at `~/.local/libexec/seatgauge-log-probe`. It uses the existing SSH login, without a password prompt. Repeat after upgrading the app. A missing helper shows up as a Log problem.

## Collection and privacy

The probe uses herdr pane and process information, then `lsof -b` on each agent PID. Codex can hold several rollouts, forks included. Each file has one owner and contributes once. Claude can report its session through herdr. Otherwise the probe matches its profile, working folder and file creation time within two minutes of process start. An ambiguous match keeps tokens pending.

The machine-local helper uses the Spend parsers and keeps a byte offset, numeric usage events and running totals for each file. A partial line waits until it is complete. Each Claude message ID counts once. Codex resumes use Spend's first-token ordering, including across read budgets, with a separate baseline for each forked session ID.

Seat Gauge decodes only usage metadata from the log records it needs, and never inspects, keeps or sends message content. The public file contains no transcript paths, process arguments, prompts, or commands. Each machine keeps its pane observations in the private `log-private/observations.jsonl`, with a replaceable `offsets.json` checkpoint beside it. A pass appends a line only for a session that changed (an open one also every ten minutes, so a row that goes stale says about when it was last seen), and once the file holds more than four lines per session (and more than 256) it is rewritten as one line per session, the last each one had. A ledger over 64 MB was written before compaction, so the first compaction keeps it beside the new one as `observations-before-compaction-<time>.jsonl`, which nothing reads and you can delete. The directory is owner-only, and the files use mode 600. If you delete the checkpoint, the helper rebuilds token totals from the source logs, while the ledger keeps pane history. Keep the ledger if you want observations to outlast their panes.
