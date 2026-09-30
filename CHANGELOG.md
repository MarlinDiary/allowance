# Changelog

## 0.6.19

- Open quietly at user login through macOS's native `SMAppService.mainApp`, registered once on the first normal installed launch. No new helper, LaunchAgent, main window or menu row.
- Respect removal or disabling in System Settings on later launches. Builds and diagnostics never automatically register login items.
- Add read-only login-item status and explicit enable/disable controls for local acceptance and rollback. Menu layout, icon, usage sources and notifications are unchanged.

## 0.6.18

- New clear-glass app icon: a silver Liquid Glass arc over a faint track, like a partly used allowance, on a neutral grey glass backplate. Default and Dark appearances keep the same colours, matching the system's Clear icon style; Tinted and Clear follow the system.
- The arc is filled outline artwork, so the icon Apple generates for macOS 13–15 shows the same hollow gauge. Icon checks now reject a recoloured stroke, which that generated icon fills as a solid wedge.

## 0.6.17

- Claude Code shows its overall weekly limit across models instead of the Fable limit. Model-specific limits such as Fable are never substituted for it, and a saved Fable reading is never restored as weekly.
- Percentages show how much of each weekly limit is used, matching the bar's fill.
- Background Keychain reads never show a system prompt, and a pending prompt can no longer stop refreshes. Previously an unanswered prompt could leave both providers without updates for hours.
- Account switches are noticed as soon as Codex or Claude Code writes its login file, including rewrites in place, and the previous account's reading disappears at once. A Claude organization change counts as a switch, since its weekly limit is per organization.
- A notification names the new account (its email) when Codex or Claude Code switches accounts while Allowance is running.
- Each provider refreshes when its request spacing ends instead of on a fixed two-minute tick. A connection failure with no provider response retries after 30 seconds, and a refresh right after wake waits briefly for the network.
- Usage and reset requests identify the bundled app version.

## 0.6.16 (release candidate; not published)

- Draft only; its request-identity change ships in 0.6.17.

## 0.6.15

- Use only the dark charcoal app icon: one complete silver ring, without an opening, needle or colored arc. Default and Dark appearances share the same fixed dark backplate, matching the selected Icon Composer reference.
- The older-OS static icon is also dark, with identical ring geometry. Native menu, menu-bar symbol and live data are unchanged.
- Verify the complete circle, dark-only backplate and matching legacy artwork.

## 0.6.14 (source preview; not published)

- Replace the gauge with one silver open-ring silhouette. A small 16-degree opening at 1:30 has lightly softened corners; no needle, colored quota arc or tick marks. Ring size and thickness are preserved.
- Keep genuine Icon Composer glass and a separate system backplate. Older macOS receives the same ring artwork as static ICNS.
- Native menu, menu-bar symbol, usage data and hidden Command-Q are unchanged. Add source geometry and legacy-artwork regression checks.

## 0.6.13 (source preview; not published)

- Unify the ring, allowance arc and needle into one foreground SVG and one shared material group, above the separate glass backplate. Preserve geometry and colors; enable shared glass highlights with 16% neutral shadow and 12% translucency. Native menu and menu-bar glyph are unchanged.
- Validate the compiled foreground plane in every appearance, with regression checks against split groups and missing foreground glass.

## 0.6.12

- Keep the three material layers but disable optically uneven specular highlights, reduce shadows to 8% and translucency to 4%. Preserve circular gauge geometry and native menu UI.

## 0.6.11

- Correct release bundle naming and add a regression guard against temporary build names in public ZIPs. The 0.6.10 preview was withdrawn during public-package verification.

## 0.6.10 (source; preview withdrawn)

- Genuine three-group Liquid Glass app icon using Apple's Icon Composer format and asset compiler. Generated ICNS supports older macOS.
- Existing native menu, menu-bar glyph, layout, bar colors and hidden Command-Q are unchanged.
- Icon validation, explicit legacy/layered build modes, two-OS CI, pinned checkout and clearer contributor/release documentation.
- Packaging: required-notarization gate, acceptance checks, app/DMG stapling when a profile is configured, and temporary-directory cleanup.

## 0.6.9

- Restored Command-Q in the native open menu without a visible Quit command.

## 0.6.8

- Removed the visible Quit row while preserving standard menu presentation.

## 0.6.7

- Removed separator lines.

## 0.6.6

- Distinguishable used fill and remaining track with a complete 4pt bar.

## 0.6.4–0.6.5

- Account-aware weekly data, quiet refresh backoff, additional Claude data paths and deduplicated reset notifications.
