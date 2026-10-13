---
name: seat-gauge
description: Read how much room each subscription seat (Claude and Codex) has left, from Seat Gauge's live file. Use when choosing which seat to run work on, or when asked how much of a seat's 5-hour or weekly usage is left.
metadata:
  owner: Launch Astro
  version: 0.1.0
  updated: 2026-10-13
---

# Seat Gauge headroom

Seat Gauge writes every seat's usage to one file after each poll. Reading it is free. Read the file; booting a seat or running `/usage` to check spends that seat.

```sh
jq -r '"updated \(.updated)", (.seats[] | "\(.id) \(.kind) stale=\(.stale) 5h_left=\(.five_hour.left // "-")% week_left=\(.weekly.left // "-")% week_resets=\(.weekly.resets // "-")")' \
  "$HOME/Library/Application Support/com.launchastro.seatgauge/headroom.json"
```

- A seat's room is its lowest `left`.
- `stale=true` means an old reading: pick another seat.
- Several lanes: spread them across seats by room. A week resetting within a day with room left is spare; use it first.

`readings.json` beside it is the app's internal store; read `headroom.json`.
