# The spend roll-up is a record, keyed by the seat that spent

`spend.csv` is the only copy of spend that outlives Claude Code's 30-day transcript cleanup, so it is never regenerated wholesale. Unsealed cells are replaced from the logs. Sealed cells, 48 hours after their hour, are never touched.

Its `seat` column is `default` for `~/.claude`, `codex` for Codex, and the seat's id for a Claude seat's own profile, which the roll-up reads from wherever `seats.json` puts it. No Claude seat may be named `default` or `codex`. Removing a seat from `seats.json` leaves its rows intact and readable. Its profile is no longer walked, so it gains no new ones.

The gauge leaves its own polls out by skipping any transcript whose `cwd` is the app's `primer/` directory. The roll-up prices the dollar column at write time from a versioned rate table, and the app presents it as a floor: the list-price value of the tokens used.
