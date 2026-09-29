# A Foundation-only core with boundary parsers and an injectable process runner

Domain types, pace, best seat, alert policy, config, the spend roll-up and both fetchers live in `SeatGaugeCore`, which imports Foundation only.

Each transport's shape (Claude control responses, Codex JSON-RPC) is known in exactly one parser. The parser turns it into a single `Window` shape: a count-up percentage and a reset instant. The different spellings of the same fields across transports never reach the UI.

Fetchers take a `ProcessRunning` so tests replay hand-written transcripts without spawning a CLI. A `seatgauge-cli` target runs the core headless, so every part below the window can be checked from a terminal. The app target holds only AppKit, SwiftUI and the main-actor state.
