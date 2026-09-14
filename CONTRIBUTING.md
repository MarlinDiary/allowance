# Contributing

Keep Allowance narrow, native and quiet. Discuss new providers, account managers and additional windows before implementing them.

1. Open a focused issue or pull request.
2. Reproduce the behavior with account-free fixtures.
3. Make the smallest change and add a regression test.
4. Run `swift test`, an app build, `--self-check` and `Scripts/verify-icon.py`.

Do not attach tokens, cookies, Keychain dumps, login files, email addresses or unredacted account responses. Diagnostics are opt-in and must not mutate credentials or bypass refresh gates.

The menu must remain a standard `NSStatusItem.menu` / `NSMenu`. Preserve its native material and positioning, read-only rows, filled-means-used convention and local hidden Command-Q. No global keyboard monitors or custom glass windows. App icon vector source is in `Assets/AppIcon.icon`; menu-bar and provider template artwork is separate.

No third-party package dependencies are required. Reference-app behavior may inform discussions; do not copy reference-app source or proprietary artwork.
