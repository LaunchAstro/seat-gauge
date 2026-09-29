# The gauge reads one identity field, to tell which seat the main login is

This amends ADR 0001, under which the gauge would read nothing from a login.

Work run under the main login lands in `spend.csv` under `default`, whichever account `~/.claude` was signed into at the time. Without knowing that account, the Spend tab and the cards cannot say whose usage it was.

The gauge reads exactly one identity field, `oauthAccount.accountUuid`, from `~/.claude.json` and from each Claude seat profile's `.claude.json`, once per poll. It keeps the values in memory only, compares them, and drops them. No id is logged, printed or written anywhere. It never reads a token and never refreshes one. The only thing it writes is the matched seat name, into `attribution.json`, which is a projection over `spend.csv` and never rewrites it (ADR 0004).

Two more fields are read for the same kind of reason, to show a card's exact plan: `oauthAccount.organizationRateLimitTier` from a Claude login file, and the `chatgpt_plan_type` claim from the payload of Codex's `id_token`. Each read keeps the one value and discards the rest where it was parsed.

The rest of ADR 0001 stands: every usage reading still comes through the seats' own CLIs.
