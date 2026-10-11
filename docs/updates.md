# App updates

Jarvis uses Sparkle 2.10.0 for signed updates and GitHub Releases for distribution. The update feed is `https://github.com/aoppenh1-afk/J.A.R.I.S/releases/latest/download/appcast.xml`. No GitHub token is stored in the app.

General settings include automatic checking, automatic downloading, and Check for Updates. Checking is enabled by default; downloading is opt-in. The popover menu also includes Check for Updates. Sparkle owns these preferences and applies them immediately.

Update archives are verified before extraction, and the app requires a signed feed. `SUPublicEDKey` in `Packaging/Info.plist` contains the public Ed25519 key. The private key is stored in the owner's login Keychain under Sparkle account `com.jarvis.voice-assistant`, and in GitHub Actions secret `SPARKLE_PRIVATE_KEY`. It is never committed. Keep the existing key when rebuilding or releasing this app.

## Personal releases without a paid Apple account

The release workflow defaults to `personal` mode. It builds and packages Jarvis on GitHub, applies ad hoc code signatures to the app and Sparkle's helpers, and signs the update archive and feed with the existing Ed25519 update key. It requires no Apple certificate, Apple Account password, paid developer membership, or notarization credentials. The only required secret, `SPARKLE_PRIVATE_KEY`, is already configured.

Personal builds are not Apple notarized. After downloading the first release, copy Jarvis to `/Applications` before opening it. If macOS blocks the app, try opening it, then use **System Settings → Privacy & Security → Open Anyway**. Follow [Apple's instructions](https://support.apple.com/en-us/102445) for this app-specific approval.

The first updater-enabled release, [version 0.2.0](https://github.com/aoppenh1-afk/J.A.R.I.S/releases/tag/v0.2.0), is published. Download its DMG or ZIP, then install it once to replace the older app. The release workflow passed, and both the public feed and archive were downloaded without authentication and verified against Jarvis's public update key.

Ad hoc signatures do not provide a stable Apple developer identity across builds. macOS may ask for microphone, Keychain, or other permissions again after an update. Credential and permission persistence across personal builds still needs physical testing. Sparkle continues to verify the update archive and feed against Jarvis's public key. [Sparkle's setup guide](https://sparkle-project.org/documentation/) treats Developer ID signing and notarization as recommended when available.

The personal app's entitlements allow its embedded Sparkle framework to load without an Apple Team ID. Developer ID builds use the stricter original entitlements. No release or installation script changes the Mac's Gatekeeper settings.

## Optional Developer ID releases

If you later join the Apple Developer Program, set repository variable `JARVIS_RELEASE_MODE` to `developer-id` and configure the values below. This mode requires Developer ID signing and notarization. Set the mode back to `personal`, or remove the variable, to use personal builds again. Do not change Jarvis's Ed25519 update key when switching modes.

In the repository's **Settings → Secrets and variables → Actions**, supply:

| Name | Kind | Value |
| --- | --- | --- |
| `APPLE_SIGNING_IDENTITY` | Variable | Complete `Developer ID Application: … (TEAMID)` identity |
| `APPLE_TEAM_ID` | Variable | Apple developer team ID |
| `APPLE_SIGNING_CERTIFICATE` | Secret | Base64-encoded `.p12` certificate export, including its private key |
| `APPLE_SIGNING_PASSWORD` | Secret | Password protecting that export |
| `APPLE_ID` | Secret | Apple Account email for notarization |
| `APPLE_APP_PASSWORD` | Secret | Apple app-specific password for notarization |
| `SPARKLE_PRIVATE_KEY` | Secret | Existing Sparkle private seed; required in both modes and already configured |

Use GitHub's secret input or `gh secret set NAME` with standard input. Do not paste secrets into issues, commit messages, source, or command arguments. Certificate exports and private-key files are ignored by Git.

[Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [certificate export instructions](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html), and [app-specific passwords](https://support.apple.com/102654) describe the account steps.

## Release a version

Push a stable version tag such as `v0.2.0`, or run **Release macOS app** manually using an existing tag. GitHub builds the app, so you do not need to rebuild it locally for each release. The workflow:

1. Checks the release mode and required credentials, then checks out the requested tag.
2. Runs tests and packages the Apple Silicon app, signing Sparkle's helpers with the same identity as Jarvis. Personal builds use ad hoc signatures.
3. Creates a ZIP and DMG. Developer ID mode also notarizes the app and DMG, staples the tickets, and validates the result.
4. Generates a signed appcast and checks its download URL, archive length, and version, then verifies both Ed25519 signatures against the public key in the packaged app.
5. Uploads the ZIP, DMG, and appcast to a draft release, then publishes it as the latest release. Release notes identify the signing mode and explain initial installation.

The marketing version comes from the tag. The build number is `1000 + GITHUB_RUN_NUMBER`, so published builds increase beyond the existing development build number. Published releases cannot be overwritten by the workflow; use a new tag for a new update. Failed draft releases can be retried.

Install the first build containing Sparkle once. Later releases can be installed from inside Jarvis. The old installed app does not contain an updater and cannot discover its own replacement. Until the first release is published, the feed URL has no release asset to download.

`Checks` uses an Apple Silicon macOS 26 runner with the SDK needed to compile the app's Liquid Glass window chrome. It runs tests, validates personal app packaging and ZIP/DMG generation, and scans all fetched Git history for secrets on pushes and pull requests. Release jobs run only for tags or manual dispatch, never for pull requests.

## Local validation

```bash
JARVIS_SIGNING_IDENTITY=- ./scripts/package-macos.sh
JARVIS_REQUIRE_PERSONAL_SIGNATURE=1 JARVIS_REQUIRE_UPDATER_CONFIGURATION=1 ./scripts/validate-installed-app.sh
JARVIS_RELEASE_MODE=personal ./scripts/make-release-artifacts.sh
```

The packaged app includes `Contents/Frameworks/Sparkle.framework`, with signatures applied inside-out. ZIP packaging preserves framework symlinks and executable permissions. Personal release validation requires an ad hoc signature and the entitlement needed to load Sparkle. Developer ID release validation continues to reject ad hoc signatures.

Both SwiftPM and the Xcode project reference the same pinned Sparkle version. If it changes, regenerate the Xcode project and retest packaging. See [Sparkle's setup guide](https://sparkle-project.org/documentation/) for framework and appcast details.
