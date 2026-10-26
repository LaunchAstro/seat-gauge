# Context

The words Seat Gauge uses, and what each one means. Terms only, no implementation.

- **Seat**: one paid AI subscription login, run beside others. Seats are listed in `seats.json`, for example `personal`, `work` and `codex`.
- **Seat kind**: which CLI reads a seat, `claude` or `codex`.
- **Profile**: a Claude seat's own config directory, such as `~/.seat-gauge/profiles/work`, the folder first launch looks in. Every Claude seat has one, so no card reads whatever `~/.claude` is signed into.
- **Own login**: a Claude seat that signs in from the login inside its profile. It reads every window and its exact plan.
- **Token seat**: a Claude seat that signs in with an OAuth token read from a file. It reads the 5-hour and weekly windows only.
- **Window**: a quota bucket on a seat. Every readable seat has a **weekly window**. A Claude seat also has a **5-hour window** and a model-scoped **Fable window**. A Codex seat may report the weekly window only. One to three windows per seat is normal.
- **Used**: the share of a window already consumed, as a percentage. Every figure on the panel counts up.
- **Headroom**: what is left in a window, 100 minus used. A seat's headroom is that of its tightest window.
- **Reset**: the moment a window refills, shown as a countdown.
- **Best seat now**: the readable seat whose tightest window has the most headroom. A tie goes to the seat listed first.
- **Pace**: whether the weekly window is on course to be fully used by its reset, judged from usage so far against time elapsed. Shown as a plain-English verdict and never part of the best-seat pick.
- **Plan**: what a seat pays for, such as `Max 20x` or `Pro`. Taken from the login file's tier, or its organisation type when the tier names no plan (as a Pro login's does), then the plan written in `seats.json`, then the usage reply's own word. Never guessed as free.
- **Dormant**: a seat that cannot be read right now, because it is switched off or not logged in. Hidden until it reads again.
- **Stale**: a seat whose last read failed. Its last reading stays on the card, dimmed and dated.
- **Open command**: a seat's own command in `seats.json`, which a click on its card's mark or name runs to start a fresh session on that seat. Optional; a seat without one has no click. A signed-out seat's click signs it in instead.
- **Headroom file**: `headroom.json`, the seats and their windows as the cards show them, written after every poll or sync for an agent to read. Data per seat, with no single seat picked.
- **Panel**: the always-on-top window that shows the cards.
- **Card**: one seat on the panel. Its glance face shows the windows; hovering turns it to the detail face with account, plan, pace and a usage chart.
- **Chosen height**: the height the panel was last dragged to. The panel keeps it across reopens and relaunches, and spends the extra room on thicker meters and wider gaps. It gives way when the cards need more.
- **Poll**: one pass that reads every seat, on the interval in `seats.json`.
- **Primer**: the working directory the gauge's own CLI calls run in, so their transcripts can be left out of spend.
- **Spend**: tokens and list-price dollars per account per hour, rolled up from local Claude Code transcripts and Codex rollouts into `spend.csv`. A floor, since some billed calls are never transcribed.
- **Sealed**: a spend cell 48 hours past its hour. It is never rewritten, because the transcripts behind it may be gone.
- **Attribution**: which seat the default `~/.claude` login was at a given hour, so spend under `default` lands on the right account.
- **Machine**: a computer whose load the LOAD tab shows, this Mac or another read over ssh. Listed under `machines` in `seats.json`.
- **Room** (of a machine): `free`, `busy` or `full`, from CPU and memory averaged over 30 seconds against the 60 and 85 percent lines, load per core against 2 and 3, and disk under 25 or 10 GB free.
- **Trend**: whether a machine's CPU or memory is `rising`, `steady` or `falling`, its last 30 seconds against the 30 before.
- **Machines file**: `machines.json`, each machine's CPU, memory, disk, room and agent count, written every read (5 seconds by default) for an agent to read, and copied once a minute to each other listed machine that answered, at the same path there.
- **Clearable folders**: the fixed list of caches and build output a machine can clear when disk runs short, sized every 15 minutes at background priority and named beside `free_gb` in the machines file. Seat Gauge never deletes them.
- **Session log**: `log.json`, one row keyed by machine and session id, with workspace, pane, branch, observed lifecycle and token totals from the Spend parsers. The Log tab draws these rows. Private pane observations stay in a ledger on each machine, one line per change, compacted to one line per session as it grows.
