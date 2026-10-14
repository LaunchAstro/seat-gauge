# Seat Gauge and Langfuse answer different usage questions, and are never added together

Agent-session tracing (Langfuse's Claude Code and Codex hooks) can run beside Seat Gauge. Both read the same local transcripts and rollouts, so together they count the same tokens twice, and both price them at list rates rather than what a flat plan bills.

Seat Gauge is the record for seat room: the 5-hour, weekly and Fable windows, their resets, the plan and which seats have room. It is also the record for account spend history: `spend.csv` keeps sealed hours that no tracer can backfill once Claude has pruned the transcripts behind them (ADR 0004). And it is the record for machine load, in `machines.json`.

Langfuse is the record for what one session, lane or ticket did: its tokens, its estimated cost and its tool calls.

Their figures are never summed or compared as if they were different spend. Each keeps its own price table, so a Langfuse cost is read as an estimate beside Seat Gauge's, not a correction of it. Tracing is opted into per repository, since a trace holds whole prompts, code and tool output. Seat Gauge's own polls start their CLIs with hooks and plugins off, so no tracer records them.
