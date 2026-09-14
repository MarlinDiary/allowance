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

```sh
export CODE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export NOTARY_PROFILE='your-existing-keychain-profile'
ALLOWANCE_ICON_STYLE=layered bash build.sh
python3 Scripts/verify-icon.py dist/Allowance.app --require-layered
REQUIRE_NOTARIZATION=1 bash Scripts/package.sh dist/Allowance.app dist
```

Packaging waits for Apple's acceptance, staples/validates the app, creates the ZIP and signed DMG, then notarizes/staples/assesses the DMG before checksumming it. Inspect `notary-app.json` and `notary-dmg.json` and retain both acceptance records. The scripts consume an existing profile; they do not store credentials.

Without a usable profile, publish only an explicitly labeled signed **prerelease**. Developer ID signing alone is not notarization. Never claim source or preview builds passed Apple notarization.

## Public artifacts

- App version/build, Git tag and release notes must agree.
- Publish ZIP, DMG and SHA256SUMS, not caches or internal account evidence.
- Download actual public assets; verify checksums, signature, compiled icon, stapling/Gatekeeper status and the DMG's Applications link.
- Preserve Git/release history; do not replace versions or force-push.
- Remove local staging apps and old installers once verification is recorded; retain one installed app and compressed rollback material.

Apple: [Icon Composer](https://developer.apple.com/icon-composer/) · [Notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
