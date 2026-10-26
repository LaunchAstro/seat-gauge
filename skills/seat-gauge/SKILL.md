---
name: seat-gauge
description: Read how much room each subscription seat (Claude and Codex) has left, and how loaded each machine is (CPU, memory, disk, agents working), from Seat Gauge's live files. Use when choosing which seat or machine to run work on, when asked how much of a seat's 5-hour or weekly usage is left, or when checking whether a machine has capacity for more agents.
metadata:
  owner: Launch Astro
  version: 0.4.0
  updated: 2026-10-26
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

## Machine load

`machines.json` beside it holds each machine's load, refreshed every 5 seconds. Also free to read.

```sh
jq -r '"updated \(.updated)", (.machines[] | "\(.id) room=\(.room // "-") why=\(.why | join("; ")) stale=\(.stale) cpu=\(.cpu.used // "-")% (\(.cpu.trend // "-")) load/core=\(.cpu.load_per_core // "-") ram=\(.ram.used // "-")% (\(.ram.trend // "-")) disk_free=\(.disk.free_gb // "-")GB disk_10m=\(.disk.change_10m_gb // "-")GB agents working=\(.agents.working // "-") idle=\(.agents.idle // "-") blocked=\(.agents.blocked // "-")")' \
  "$HOME/Library/Application Support/com.launchastro.seatgauge/machines.json"
```

- CPU and RAM are 30-second averages; `trend` says whether they are rising, steady or falling.
- `room`: `free` takes more agents, `busy` takes a few, `full` takes none until it eases. `why` names the cause.
- Load per core above 1 means work is queueing; 3 is the build method's ceiling.
- Disk under 25 GB free, or `disk_10m` falling by gigabytes: time to clear caches and old build output.
- `stale=true` or a `problem`: the machine could not be read; do not send it work blind.
- `blocked` agents are waiting on a person.
- On another machine the app lists, the same path holds a copy, refreshed once a minute. `updated` over two minutes old: the copies have stopped; check this machine alone and say so. No file there: that machine is not on the app's list, or never answered it.
- `headroom.json` exists only on the Mac running the app.
