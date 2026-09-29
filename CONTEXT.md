# Context

The words Seat Gauge uses, and what each one means. Terms only, no implementation.

- **Seat**: one paid AI subscription login, run beside others. Seats are listed in `seats.json`, for example `personal`, `work` and `codex`.
- **Seat kind**: which CLI reads a seat, `claude` or `codex`.
- **Profile**: a Claude seat's own config directory, such as `~/.claude-seat-work`. Every Claude seat has one, so no card reads whatever `~/.claude` is signed into.
- **Own login**: a Claude seat that signs in from the login inside its profile. It reads every window and its exact plan.
- **Token seat**: a Claude seat that signs in with an OAuth token read from a file. It reads the 5-hour and weekly windows only.
- **Window**: a quota bucket on a seat. Every readable seat has a **weekly window**. A Claude seat also has a **5-hour window** and a model-scoped **Fable window**. A Codex seat may report the weekly window only. One to three windows per seat is normal.
- **Used**: the share of a window already consumed, as a percentage. Every figure on the panel counts up.
- **Headroom**: what is left in a window, 100 minus used. A seat's headroom is that of its tightest window.
- **Reset**: the moment a window refills, shown as a countdown.
- **Best seat now**: the readable seat whose tightest window has the most headroom. A tie goes to the seat listed first.
- **Pace**: whether the weekly window is on course to be fully used by its reset, judged from usage so far against time elapsed. Shown as a plain-English verdict and never part of the best-seat pick.
- **Plan**: what a seat pays for, such as `Max 20x` or `Pro`. Taken from the login file's tier, then the plan written in `seats.json`, then the usage reply's own word. Never guessed as free.
- **Dormant**: a seat that cannot be read right now, because it is switched off or not logged in. Hidden until it reads again.
- **Stale**: a seat whose last read failed. Its last reading stays on the card, dimmed and dated.
- **Headroom file**: `headroom.json`, the seats and their windows as the cards show them, written after every poll or sync for an agent to read. Data per seat, with no single seat picked.
- **Panel**: the always-on-top window that shows the cards.
- **Card**: one seat on the panel. Its glance face shows the windows; hovering turns it to the detail face with account, plan, pace and a usage chart.
- **Chosen height**: the height the panel was last dragged to. The panel keeps it across reopens and relaunches, and spends the extra room on thicker meters and wider gaps. It gives way when the cards need more.
- **Poll**: one pass that reads every seat, on the interval in `seats.json`.
- **Primer**: the working directory the gauge's own CLI calls run in, so their transcripts can be left out of spend.
- **Spend**: tokens and list-price dollars per account per hour, rolled up from local Claude Code transcripts and Codex rollouts into `spend.csv`. A floor, since some billed calls are never transcribed.
- **Sealed**: a spend cell 48 hours past its hour. It is never rewritten, because the transcripts behind it may be gone.
- **Attribution**: which seat the default `~/.claude` login was at a given hour, so spend under `default` lands on the right account.
