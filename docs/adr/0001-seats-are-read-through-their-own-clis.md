# Seats are read through their own CLIs, never through their tokens

Each poll runs the seat's own tool headless and parses what it prints. For Claude that is `claude -p` and the `get_usage` control request, after one Haiku turn for a token seat only. For Codex it is `codex app-server` with `account/rateLimits/read`. The gauge never reads the Keychain, never calls a usage endpoint itself, and never refreshes a token.

The cost: a large binary started per poll. A Claude seat with its own login answers `get_usage` in full with no turn, so its check is free. A token seat answers it empty and reports its windows only during a turn, so it is never polled on the timer, and each sync the user asks for costs one small Haiku turn. The alternative, calling the usage endpoints with the seats' credentials, would put the gauge in a refresh race with the CLIs (the Codex refresh token is single-use and rotates) and put credentials in the app's hands.

Amended by ADR 0005, which allows a few named fields to be read from login files.
