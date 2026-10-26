# Security

## Reporting a problem

Please report a security problem privately, through this repository's Security tab: choose "Report a vulnerability". This uses GitHub's private vulnerability reporting, so only you and the maintainers see the report. Don't open a public issue, pull request or discussion for it.

Say what you found, the version (`seatgauge-cli --version`) and the commit you built (`git rev-parse --short HEAD` in your clone), your macOS version, and the steps that show it. Leave out real tokens, emails, account ids and transcripts; a made-up value in the right shape is enough.

We aim to reply within a week. There is no bug bounty.

## What is in scope

Seat Gauge runs the `claude` and `codex` CLIs under your own logins, so we treat as a security problem anything that could:

- Leak or misuse a login: a seat reading another seat's login, the main `~/.claude` login, or an OAuth token reaching anything other than that seat's own `claude`.
- Expose a token file or login file, or what the app reads from one (plan, organisation type, account id), beyond what the README says it reads.
- Let something into a CLI child's environment that should not be there, such as an inherited API key, or run a command you did not ask for, including through `seats.json`, a seat's `open` command, a sign-in or an ssh machine.
- Write anything sensitive to disk, a log or the title bar: tokens, sign-in codes, emails, account ids, transcript content or paths it should not keep. This covers `spend.csv`, `headroom.json`, `machines.json`, `log.json`, the Log tab's private ledger, `seatgauge-cli record` output and the sign-in script.
- Make the installer or the app delete, replace or change files it did not create.

A bug in a figure on a card, the Spend tab or the LOAD tab is an ordinary issue unless it also does one of the above.

## Supported versions

Only the latest release is supported. Seat Gauge is built from source; a fix lands on `main` and in the next release.
