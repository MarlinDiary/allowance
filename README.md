# Allowance

A small, native macOS menu-bar utility for **Codex weekly** and **Claude Code Fable
weekly** allowance. English UI. No dashboard, no main window, no Refresh button.

- Shows the currently signed-in CLI account's remaining percentage and reset time.
- A thin, read-only quota bar shows **used** quota; the empty portion is remaining.
- **Slow · Steady · Fast** compares usage with elapsed time in the weekly window
  (a five-percentage-point tolerance). These words describe pace, not model mode.
- Native `NSMenu` presentation, SwiftUI information rows, a two-tone SwiftUI quota bar and bundled template
  artwork. No custom glass, popover or hover explanations.
- Tibo's explicit upcoming reset announcements and confirmed executions become
  standard macOS notifications. Banked resets and AI forecasts are excluded.

## Install

Download the ZIP or DMG from [Releases](https://github.com/MarlinDiary/allowance/releases),
move **Allowance.app** into Applications, and open it. Existing Codex / Claude Code
logins are used; no separate sign-in screen. Allow notifications when macOS asks.
To change notification access later, use System Settings → Notifications → Allowance.
Quit is the sole normal menu command. No automatic launch-at-login modification.

## Data sources and quiet refreshes

Codex uses its existing local login and weekly usage endpoint. Claude reads a
fresh, account-matched Fable cache first, then existing OAuth credentials or an
existing Safari / Claude Desktop web session. The web path verifies the server
account and organization before fetching usage. Shared/all-model weekly quota is
never substituted for Fable. See [CLAUDE_SOURCES.md](CLAUDE_SOURCES.md).

Every refresh trigger shares a persisted per-provider gate: Codex at least two
minutes, Claude at least five. Rate limits cause quiet backoff (5 / 10 / 20 / 30
minutes; a longer Retry-After wins), not more attempts through another source.
Recent cached readings stay quiet. Old readings say **last known** and **Delayed**
rather than pretending to be fresh. Actionable sign-in/permission errors remain visible.

Changing the active CLI account changes only that provider. Late responses from
an old account are discarded. Finder launches use the default profiles; custom
CLI configuration directories require launching with the corresponding environment.

### Reset notifications

The independent [CodexResets public feed](https://codex-resets.com/api/docs) is
polled every five minutes using conditional ETag requests. Its `scheduled_reset`
field supplies explicit Tibo announcements; `latest_reset` supplies executed
resets. Merely passing the scheduled time does **not** confirm execution. An
observed execution is labeled as observed, not attributed to a Tibo post.

On first launch, the historical latest execution is silently baselined; a current
pending announcement is useful immediately. Announcement and execution IDs are
persisted separately so each can notify once, including across restarts. Failed
OS submissions retry on a later eligible poll. Forecasts, banked resets and events
older than a week are ignored. Feed failures never add menu error rows. Notifications
are global-feed observations, not proof that every account has already updated.
macOS permission, Focus and notification settings control presentation. This is
periodic polling, not a server APNs subscription.

The read-only bar uses two standard SwiftUI `Capsule` shapes at **4pt**, not a
compressed AppKit control. A stronger used fill and faint remaining track stay
distinct on light, dark and wallpaper-tinted menu backdrops. Increased Contrast
raises the distinction further. The native menu material, position, dimensions,
text sizes and actions are unchanged. Filled always means used, never remaining.

## Privacy

No analytics, telemetry, credential upload to a project server, account creation,
CLI subprocess/inference probes or credential refresh/write. Existing login files,
Keychain entries and browser session stores are read locally. Cookies are sent only
to Claude, OAuth tokens only to their provider, and reset requests need no account
credentials. One last-good snapshot and scheduling state per provider are stored
in local app preferences, bound to account identity. Reset notice IDs are also
stored locally. Diagnostic output excludes tokens, emails and account identifiers.

Public sources contain no local account data or release-signing credentials.
Provider trademarks are described in [NOTICE.md](NOTICE.md).

## Build and test

Requires Xcode / Swift 6.0 or newer; deployment target macOS 13.

```sh
swift test
bash build.sh                        # universal arm64 + x86_64, ad-hoc source build
open dist/Allowance.app
./dist/Allowance.app/Contents/MacOS/Allowance --self-check
./dist/Allowance.app/Contents/MacOS/Allowance --source-check  # no HTTP
./dist/Allowance.app/Contents/MacOS/Allowance --live-check    # respects cooldown
```

`ALLOWANCE_ARCHS=arm64` builds only Apple Silicon. `ALLOWANCE_BUILD_DIR` overrides
build scratch storage. Internal Swift target names retain `QuotaMenu` / `QuotaCore`
for continuity; the app name and bundle identity are Allowance.

Developer ID builds: set `CODE_SIGN_IDENTITY`, then run `build.sh`. Run
`Scripts/package.sh` to make ZIP/DMG/checksums. Setting `NOTARY_PROFILE` to an
existing Keychain profile enables Apple notarization and stapling during packaging.
No credentials are embedded or stored by these scripts. Existing output paths are
never overwritten. See the release notes for the actual published signing status
and validation boundary rather than assuming source builds are notarized.

Tests cover parsing, account changes, passive-cache validation, HTTP gates, restart
state, late-response rejection, tint resolution, offscreen native rendering,
reset classification/deduplication, URL validation, backoff and preference migration.
Native component renders are not full desktop/menu screenshots. The release is
validated on the maintainer's Apple Silicon Mac; Intel and macOS 13–26 runtime and
long-duration idle/energy behavior are not yet validated.
