# Distribution — signing, notarization, release

Toolbox ships as a **signed + notarized DMG** with **Sparkle** auto-updates,
published to GitHub Releases. The whole pipeline is one command; this page
covers what it does and what it needs.

## The pipeline

| Command | Does |
|---|---|
| `./scripts/build-app.sh --fast` | debug build + sign (local iteration) |
| `./scripts/build-app.sh --notarize` | release build → sign (Developer ID) → notarize + staple → `build/Toolbox.app` |
| `fastlane distrib` | release build + notarize + staple → `build/Toolbox.dmg` |
| `fastlane release` | `distrib` + Sparkle update zip + GitHub release + appcast (commit + push) |

## What you need (one-time)

- An **Apple Developer account** with a **Developer ID Application**
  certificate in your keychain (`security find-identity -v -p codesigning`)
- A **notarytool** keychain profile named `notary-profile`
  (`xcrun notarytool store-credentials …`)
- **Fastlane**, **Node.js**, and the **gh** CLI (authenticated)
- The **Sparkle EdDSA private key** in your keychain
  (corresponding to `SUPublicEDKey` in `Resources/Info.plist`)

## Releasing

1. Bump the version in `VERSION` (e.g. `1.1`) — `./scripts/build-app.sh`
   writes it into both `CFBundleShortVersionString` and `CFBundleVersion`.
2. Add user-facing release notes under `## [Unreleased]` in `CHANGELOG.md`,
   then commit and push your changes.
3. Run `fastlane release`: builds, signs, notarizes, staples, creates
   `build/Toolbox.dmg` + `build/Toolbox-<version>.zip`, publishes the
   GitHub Release `v<version>`, converts `[Unreleased]` in `CHANGELOG.md`
   to `## [<version>] - YYYY-MM-DD`, regenerates `releases/appcast.xml`,
   and commits + pushes `releases/appcast.xml` and `CHANGELOG.md`.

Installed copies of Toolbox check `SUFeedURL` hourly and offer the new
release automatically via Sparkle.

## Notes

- The DMG has a **stable filename** (`Toolbox.dmg`) so the README's
  `releases/latest/download/Toolbox.dmg` link keeps working across releases;
  the Sparkle update zip stays versioned (`Toolbox-<version>.zip`).
- Both `Toolbox.app` and `Toolbox.dmg` work completely offline; internet
  access is only used for Sparkle update checks and downloads.
