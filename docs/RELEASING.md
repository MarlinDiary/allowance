# Release checklist

## Before publishing

- Run tests on macOS 15 and 26; inspect CI rather than assuming success.
- Build a universal arm64 / x86_64 app and verify architectures/signature.
- Require `Scripts/verify-icon.py --require-layered` for release builds.
- Recheck the installed native menu, hidden Command-Q and real account data.
- Confirm repository/diagnostic content excludes account data and credentials.
- Keep a hashed baseline archive and test executable rollback.
- State runtime/platform and long-duration validation gaps honestly.

## Local signing and notarization

Use a valid **Developer ID Application** identity and an **existing** notarytool Keychain profile. Never commit credentials.

If a profile has not been configured, create one in your own terminal. An App Store Connect API key is the most reliable: in App Store Connect → Users and Access → Integrations → App Store Connect API, generate a Team Key with Developer access, download its `.p8` once, and run `xcrun notarytool store-credentials Allowance-Notary --key <AuthKey.p8> --key-id <KEY ID> --issuer <ISSUER ID>`. Keep the `.p8` outside the repository. An Apple ID also works (`xcrun notarytool store-credentials Allowance-Notary --team-id <TEAMID>`) but needs an app-specific password for the Apple ID enrolled in that team; an ordinary password fails with HTTP 401. Enter secrets only at the tool's own prompt or from your own files, never in a chat. The tool validates credentials before storing them. Then check `xcrun notarytool history --keychain-profile Allowance-Notary` before submitting a release.

```sh
export CODE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='your-existing-keychain-profile'
ALLOWANCE_ICON_STYLE=layered bash build.sh
python3 Scripts/verify-icon.py dist/Allowance.app --require-layered
REQUIRE_NOTARIZATION=1 bash Scripts/package.sh dist/Allowance.app dist
```

Packaging waits for Apple's acceptance, staples/validates the app, creates the ZIP and signed DMG, then notarizes/staples/assesses the DMG before checksumming it. Inspect `notary-app.json` and `notary-dmg.json` and retain both acceptance records; move a previous release's artifacts out of `dist` first, since packaging rewrites them. The scripts consume an existing profile; they do not store credentials.

Without a usable profile, publish only an explicitly labeled signed **prerelease**. Developer ID signing alone is not notarization. Never claim source or preview builds passed Apple notarization.

## Public artifacts

- App version/build, Git tag and release notes must agree.
- HTTP clients use the app's bundled version for the User-Agent; do not maintain separate version literals in provider or reset requests.
- Publish ZIP, DMG and SHA256SUMS, not caches or internal account evidence.
- Download actual public assets; verify checksums, signature, compiled icon, stapling/Gatekeeper status and the DMG's Applications link.
- Preserve Git/release history; do not replace versions or force-push.
- Remove local staging apps and old installers once verification is recorded; retain one installed app and compressed rollback material.

Apple: [Icon Composer](https://developer.apple.com/icon-composer/) · [Notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
