# Releasing PasDisk

Releases are made by [release-please](https://github.com/googleapis/release-please)
and `.github/workflows/release.yml`.

1. Commit with [Conventional Commits](https://www.conventionalcommits.org/):
   `feat(gui): …` (minor), `fix(scan): …` (patch), `feat!: …` or a
   `BREAKING CHANGE:` footer (major). `docs`, `build`, `ci`, `refactor` are
   kept out of the changelog.
2. Every push to `main` updates the open **release PR** (version bump in
   `version.txt`, `src/units/Version.pas`, `packaging/Info.plist`, and
   `CHANGELOG.md`).
3. Merging the release PR tags `vX.Y.Z` and creates the GitHub release; the
   macOS job then builds `PasDisk.app`, signs it with the Developer ID,
   notarizes and staples it, and attaches `PasDisk-X.Y.Z.zip` and
   `appcast.xml`. The app's Sparkle feed is
   `https://github.com/ikari-pl/PasDisk/releases/latest/download/appcast.xml`.

`workflow_dispatch` runs the macOS build alone, ad-hoc signed, as a toolchain check.

## Secrets (repository settings)

| Secret | What |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application certificate + key, `.p12`, base64 |
| `MACOS_CERT_PASSWORD` | password of that `.p12` |
| `NOTARY_KEY_P8` | App Store Connect API key (`AuthKey_….p8` contents) |
| `NOTARY_KEY_ID` | its key ID |
| `NOTARY_ISSUER` | the issuer ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key (`generate_keys -x`) |

The Sparkle public key is `SUPublicEDKey` in `packaging/Info.plist`; the
private key also stays in the owner's login keychain.

## First release (bootstrap)

`release-please-config.json` pins `"release-as": "1.0.0"` so the first
release is 1.0.0. After that release PR is merged, **remove the
`release-as` line** in a follow-up commit (`chore: stop pinning the release
version`), or every later release PR keeps proposing 1.0.0.
