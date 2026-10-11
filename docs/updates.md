# App updates

Jarvis uses Sparkle 2.10.0 for signed updates and GitHub Releases for distribution. The update feed is `https://github.com/aoppenh1-afk/J.A.R.I.S/releases/latest/download/appcast.xml`. No GitHub token is stored in the app.

General settings include automatic checking, automatic downloading, and Check for Updates. Checking is enabled by default; downloading is opt-in. The popover menu also includes Check for Updates. Sparkle owns these preferences and applies them immediately.

Update archives are verified before extraction, and the app requires a signed feed. `SUPublicEDKey` in `Packaging/Info.plist` contains the public Ed25519 key. The private key is stored in the owner's login Keychain under Sparkle account `com.jarvis.voice-assistant`, and in GitHub Actions secret `SPARKLE_PRIVATE_KEY`. It is never committed. Keep the existing key when rebuilding or releasing this app.

## One-time release configuration

The update key and public repository are configured. Apple distribution credentials still need to be configured. An Apple Development certificate is sufficient for local builds, but releases need a Developer ID Application certificate and notarization access.

In the repository's **Settings → Secrets and variables → Actions**, supply:

| Name | Kind | Value |
| --- | --- | --- |
| `APPLE_SIGNING_IDENTITY` | Variable | Complete `Developer ID Application: … (TEAMID)` identity |
| `APPLE_TEAM_ID` | Variable | Apple developer team ID |
| `APPLE_SIGNING_CERTIFICATE` | Secret | Base64-encoded `.p12` certificate export, including its private key |
| `APPLE_SIGNING_PASSWORD` | Secret | Password protecting that export |
| `APPLE_ID` | Secret | Apple Account email for notarization |
| `APPLE_APP_PASSWORD` | Secret | Apple app-specific password for notarization |
| `SPARKLE_PRIVATE_KEY` | Secret | Existing Sparkle private seed; already configured |

Use GitHub's secret input or `gh secret set NAME` with standard input. Do not paste secrets into issues, commit messages, source, or command arguments. Certificate exports and private-key files are ignored by Git.

[Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [certificate export instructions](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html), and [app-specific passwords](https://support.apple.com/102654) describe the account steps.

## Release a version

Once the source changes are committed and pushed, push a stable version tag such as `v0.2.0`, or run **Release macOS app** manually using an existing tag. The workflow:

1. Checks required credentials, then checks out the requested tag.
2. Runs tests and packages the Apple Silicon app, signing Sparkle's helpers with the same identity as Jarvis.
3. Notarizes the app and DMG, staples the tickets, and validates the result.
4. Generates a signed appcast and checks its download URL, archive length, and version, then verifies both Ed25519 signatures against the public key in the packaged app.
5. Uploads the ZIP, DMG, and appcast to a draft release, then publishes it as the latest release.

The marketing version comes from the tag. The build number is `1000 + GITHUB_RUN_NUMBER`, so published builds increase beyond the existing development build number. Published releases cannot be overwritten by the workflow; use a new tag for a new update. Failed draft releases can be retried.

Install the first build containing Sparkle once. Later releases can be installed from inside Jarvis. The old installed app does not contain an updater and cannot discover its own replacement. Until the first release is published, the feed URL has no release asset to download.

`Checks` runs tests, validates ad hoc packaging, and scans all fetched Git history for secrets on pushes and pull requests. Release jobs run only for tags or manual dispatch, never for pull requests.

## Local validation

```bash
JARVIS_SIGNING_IDENTITY=- ./scripts/package-macos.sh
JARVIS_REQUIRE_UPDATER_CONFIGURATION=1 ./scripts/validate-installed-app.sh
```

The packaged app includes `Contents/Frameworks/Sparkle.framework`, with signatures applied inside-out. ZIP packaging preserves framework symlinks and executable permissions. Ad hoc builds validate locally but are not published by the release workflow.

Both SwiftPM and the Xcode project reference the same pinned Sparkle version. If it changes, regenerate the Xcode project and retest packaging. See [Sparkle's setup guide](https://sparkle-project.org/documentation/) for framework and appcast details.
