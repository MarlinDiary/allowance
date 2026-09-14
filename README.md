<p align="center"><img src="docs/images/app-icon.png" width="112" alt="Allowance app icon"></p>

# Allowance

A quiet, native macOS menu-bar app for **Codex weekly** and **Claude Code Fable weekly** allowance. Follows the account already signed in to each CLI.

[![Native checks](https://github.com/MarlinDiary/allowance/actions/workflows/ci.yml/badge.svg)](https://github.com/MarlinDiary/allowance/actions/workflows/ci.yml)
[Download](https://github.com/MarlinDiary/allowance/releases) · [Data sources](CLAUDE_SOURCES.md) · [Changelog](CHANGELOG.md)

- Remaining percentage, reset countdown and **Slow · Steady · Fast** usage pace.
- A thin, read-only bar: **filled = used; empty = remaining**.
- Standard macOS notifications for Tibo's explicit reset announcements and confirmed resets.
- Native `NSMenu`, compact SwiftUI information rows, English UI. No dashboard, main window, separator lines, Refresh button or hover explanations.
- A genuine layered Icon Composer app icon on macOS 26+, with a generated legacy icon for older macOS. The white template menu-bar symbol is unchanged.

<p><img src="docs/images/menu-light.png" width="260" alt="Allowance light information rows"> <img src="docs/images/menu-dark.png" width="260" alt="Allowance dark information rows"></p>

*Native component previews with fixture data, not full desktop screenshots.*

## Install

Requires **macOS 13 or later**. Download the universal Apple Silicon / Intel ZIP or DMG from [Releases](https://github.com/MarlinDiary/allowance/releases), move **Allowance.app** into Applications and open it. Existing CLI logins are used; there is no separate sign-in screen.

**Current downloads are Developer ID-signed public previews. Apple notarization is not complete; see each release's explicit signing status.** A developer certificate alone is not notarization. Do not assume an ad-hoc source build is a signed release.

Allow notifications when macOS asks. Later, change access in System Settings → Notifications → Allowance. Focus and system settings control presentation. The app does not modify launch-at-login settings.

The normal menu is information-only. **Command-Q while the menu is open** quits through a hidden native menu command, without a visible Quit row. This is not a global hotkey and never captures Command-Q from another foreground app. Activity Monitor also works. A Keychain access command appears only when needed.

## What the numbers mean

The percentage is **remaining** quota. Pace compares **used quota** with elapsed time in the seven-day window, with a five-percentage-point tolerance:

| Pace | Meaning |
| --- | --- |
| Slow | Usage is behind elapsed time. |
| Steady | Usage is approximately in step with elapsed time. |
| Fast | Usage is ahead of elapsed time. |

These words describe quota pace, not a model's fast mode or a prediction.

## Quiet, account-aware data

Codex reads its existing CLI login and weekly usage endpoint. Claude reads a fresh, account-matched Fable cache first, then existing OAuth credentials or an existing Safari / Claude Desktop web session. The web path verifies the server account and organization before fetching usage. Shared/all-model quota is **never** substituted for Fable. Details: [CLAUDE_SOURCES.md](CLAUDE_SOURCES.md).

Every refresh trigger shares a persisted provider gate: Codex at least two minutes, Claude at least five. Rate limits cause quiet backoff (5 / 10 / 20 / 30 minutes; a longer Retry-After wins), not repeated attempts through another data source. Recent cached readings stay quiet. Old readings say **last known** and **Delayed**; actionable sign-in and permission issues remain visible.

Changing the active CLI account changes only that provider. Late responses from an old account are discarded. Finder launches use default CLI configuration paths; custom profiles require the corresponding launch environment.

### Reset notifications

The independent [CodexResets public feed](https://codex-resets.com/api/docs) is polled every five minutes with conditional ETag requests. Only explicit pending Tibo announcements and confirmed executions notify. Banked resets, forecasts and events older than a week are excluded. Passing a scheduled time alone does **not** confirm a reset; observed executions are labeled as observed.

The historical latest execution is silently baselined on first launch; a pending announcement can notify immediately. Announcement and execution IDs are persisted separately and deduplicated across restarts. Failed OS submissions retry on a later eligible poll. Feed failures add no menu error rows. Notifications describe the global feed, not proof that every account has updated. This is polling, not APNs.

## Privacy

No analytics, telemetry, project-server credential upload, account creation, CLI subprocess/inference probes or credential refresh/write.

Existing login files, Keychain entries and browser session stores are read locally. Cookies are sent only to Claude, OAuth tokens only to their provider. Reset requests need no account credentials. One last-good snapshot and scheduling state per provider are saved in local app preferences, bound to account identity; reset notice IDs are also stored locally. Diagnostics exclude tokens, emails and account identifiers.

Public source contains no local account data or signing credentials. Independently implemented; not affiliated with OpenAI, Anthropic or Apple. [MIT license](LICENSE) · [Provider artwork and trademarks](NOTICE.md)

## Build and test

Swift 6 / Xcode 16 or newer; **Xcode 26+ for layered icons**.

```sh
swift test
bash build.sh                 # universal; ad-hoc, not a distribution signature
python3 Scripts/verify-icon.py dist/Allowance.app
open dist/Allowance.app
./dist/Allowance.app/Contents/MacOS/Allowance --self-check
./dist/Allowance.app/Contents/MacOS/Allowance --source-check  # no HTTP
./dist/Allowance.app/Contents/MacOS/Allowance --live-check    # respects cooldown
```

`ALLOWANCE_ARCHS=arm64` builds only Apple Silicon. `ALLOWANCE_BUILD_DIR` changes scratch storage. `ALLOWANCE_ICON_STYLE=layered` requires real layered compilation; `legacy` explicitly builds the original static SVG. Default `auto` uses Apple's layered compiler on Xcode 26+, otherwise the static fallback. Compiler failures are not silently hidden. The existing native menu route is unchanged.

See [contributing](CONTRIBUTING.md) and the [release checklist](docs/RELEASING.md). Internal Swift module names remain `QuotaMenu` / `QuotaCore` for continuity.

## Validation boundary

CI runs unit tests, app builds, self-checks and icon checks on macOS 15 and 26. Published universal builds are validated on the maintainer's Apple Silicon Mac. Intel runtime, macOS 13–14 runtime, full desktop appearance across all supported systems, and long-duration idle/energy behavior remain unvalidated.
