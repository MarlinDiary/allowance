# Changelog

## 0.6.14

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
