# Claude Fable usage sources (Allowance 0.6.5)

Independent implementation using Apple-provided frameworks only. CodexBar was
consulted for endpoint/data-shape behavior; its implementation is not included.

1. **Passive Claude Code cache** — reads `cachedUsageUtilization` from the current
   configuration's `.claude.json`. Requires its account UUID to match the active
   account hint, a real Fable model-scoped weekly window, a capture time no more
   than 15 minutes old, and a future reset date. A reading under five minutes old
   avoids a network refresh. It can update the menu during a network cooldown.
2. **OAuth** — existing CLI credentials, profile identity verification, then the
   usage endpoint. Known-expired tokens are never sent. Allowance doesn't refresh or
   rewrite Claude Code credentials or start a CLI process.
3. **Web** — existing Safari or Claude Desktop session cookies, read-only and
   noninteractive. Checks the server account UUID and membership in the selected
   CLI organization before requesting that organization's usage. No automatic
   selection of a different account or organization. Unreadable/unsupported cookie
   stores are skipped without prompting. Cloudflare challenges are not automated.
4. **Last successful Allowance observation** — one account-bound snapshot per provider
   in app preferences, restored only for a matching identity and unexpired window.
   Capture times are retained across failure and restart, not replaced with now.

OAuth is preferred initially. Recoverable credential, server or network failures
can use Web. A 429 stops further HTTP calls in that cycle. Web may be preferred on
an eligible subsequent attempt **after** the shared cooldown. All menu-open,
background, wake, credential-audit and diagnostic refreshes share that gate.

Minimum network attempt spacing: Claude five minutes, Codex two minutes. Repeated
429s back off for 5, 10, 20, then 30 minutes. A longer server Retry-After always
wins. Cooldowns and retry count survive restart, token rotation and account switch.
Only a successful network observation resets the consecutive rate-limit count.

The main menu does not display `Rate limited`. A recent cached weekly reading
keeps its normal layout and pace word; after 15 minutes or a passed reset, the
reading is last-known and the rate-limited refresh state says `Delayed`. Without a
valid observation it says `Updating`, never inventing a percentage or reset.
Other actionable login/permission errors remain visible. No hover explanation.

`--source-check` inspects source readiness without HTTP requests and prints only
availability/source names. `--live-check` respects the persisted request gate.
`--live-check --prefer-claude-web` gives Web first preference for a scheduled
source check; it does not force a request through a cooldown.

