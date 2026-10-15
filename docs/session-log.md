# Session log

The Log tab publishes `log.json` in the app's Application Support folder, beside `machines.json` and `headroom.json`. It polls the configured machines every 30 seconds. `seatgauge-cli log` performs one round and prints the same snapshot.

Each row is keyed by `machine` and `session_id`. It carries workspace and pane, tool, model and effort, repo, section, seat, branch, `started_at`, `closed_at`, status, `as_of`, `stale`, token counts, counts by model, and list-price USD. Workspace labels split from the right as `<repo>-<section>-<seat>`. A label without three parts leaves those fields empty. Unknown model prices remain empty.

Start means first observed working. `done` means a finished turn. Close means the pane disappeared or its agent process exited. A failed machine read preserves its rows with `stale` set. Consumers also compare `as_of` with their clock and reject figures older than 90 seconds, including when the app has quit.

## Remote machines

The SSH machine needs the same version of the CLI helper and herdr at `~/.local/bin/herdr`. After `make install`, run:

```sh
scripts/install-log-probe.sh <ssh destination>
```

This installs only the helper at `~/.local/libexec/seatgauge-log-probe`. It uses the existing SSH login, without a password prompt. Repeat after upgrading the app. A missing helper appears as a Log problem.

## Collection and privacy

The probe uses herdr pane and process information, then `lsof -b` on each agent PID. Codex can hold multiple rollouts, including forks. Each file has one owner and contributes once. Claude can report its session through herdr. Otherwise the probe matches its profile, working folder and file creation time within two minutes of process start. An ambiguous match keeps tokens pending.

The machine-local helper uses the Spend parsers and keeps a byte offset and running totals for each file. Partial lines wait for completion. Each Claude message ID counts once. Codex cumulative counters use the same delta and reset rules as Spend, with independent baselines for forked session IDs.

Only usage metadata is decoded from relevant log records. Message content is never inspected, retained, or transmitted. The public file contains no transcript paths, process arguments, prompts, or commands. Each machine keeps its pane observations in the private append-only `log-private/observations.jsonl`, with a replaceable `offsets.json` checkpoint beside it. The directory is owner-only, and the files use mode 600. Removing the checkpoint rebuilds token totals from the source logs while the ledger retains pane history. Keep the ledger to retain observations after panes disappear.
