# Jarvis settings and updates validation

Validated on October 10, 2026, using Apple Silicon and Swift 6.4 / Xcode 27.

- 121 JarvisCore tests pass, including automatic-save coalescing, edits during a save, invalid-value recovery, closing-window flush, legacy orb preferences, request model overrides, and Hermes model inventory decoding.
- SwiftPM packaging and the Xcode Release application target build successfully.
- The packaged app passes hardened-runtime signature, nested Sparkle signature, embedded resource, arm64, entitlement, public update key/feed, and development-path dependency checks.
- A local ZIP and appcast were generated using the Jarvis update key. Both Ed25519 signatures verify against the public key embedded in the archive. Deliberately invalid signatures are rejected.
- GitHub workflows pass actionlint. Modified packaging/validation scripts pass bash syntax and ShellCheck; the setup helper passes syntax and ShellCheck with the template's unused-color warning excluded.
- The live Hermes API supplies the model inventory, including authenticated providers and the current default.
- The actual SwiftUI SettingsView was compiled in an isolated preview app. Native controls show Models, Liquid Glass only, software updates, and automatic-save status. Toggling transcript retention invoked the application callback and persisted the preference without pressing any save button. Preview preferences were kept separate from the installed app's preferences.
- All 35 reachable Git commits, current source, GitHub metadata, and OCR from all 19 historical image blobs were checked before the repository became public. The final source scan also reports no secret candidates.

The local app is `dist/updates/J.A.R.V.I.S.app` (0.2.0, build 1000), with an ad hoc signature for local review. It has not replaced the installed app. No release has been published and the source changes have not been pushed. Apple Developer ID and notarization credentials are still required for the release workflow. A temporary human-operated setup helper is available at `/tmp/jarvis-release-setup.sh`; it was validated but not executed.

A production update installation, Apple notarization, and credential persistence across a Developer ID update remain untested until the first signed release is configured and published.
