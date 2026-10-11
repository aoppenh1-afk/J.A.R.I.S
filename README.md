# J.A.R.V.I.S.

A fully native Apple Silicon macOS voice assistant powered by local Parakeet Core ML and Hermes Agent.

## Native architecture

```text
SwiftUI menu-bar app
  → Carbon key-down/key-up hotkey
  → AVAudioEngine microphone capture
  → Parakeet Core ML or consent-gated Deepgram STT
  → Hermes HTTP/SSE through URLSession
  → AVSpeechSynthesizer or Deepgram Aura-2 TTS
```

The macOS v1 does not require Electron, Node, React, Python, Pipecat, Voice UI Kit, WebRTC, or a local IPC helper.

## Build and test

```bash
swift test --package-path apps/macos
```

Build the development executable without launching it:

```bash
./scripts/build.sh
```

Generate the native Xcode project, archive the Apple Silicon application, and validate the exported bundle without launching it:

```bash
./scripts/generate-xcode-project.sh
./scripts/archive-macos.sh
./scripts/validate-installed-app.sh
```

The archive and application are written to `dist/J.A.R.V.I.S.xcarchive` and `dist/J.A.R.V.I.S.app`. `package-macos.sh` remains available as a faster SwiftPM-based local bundle path. Release metadata and signing are configured through `JARVIS_BUNDLE_IDENTIFIER`, `JARVIS_MARKETING_VERSION`, `JARVIS_BUILD_NUMBER`, `JARVIS_SIGNING_IDENTITY`, and `JARVIS_DEVELOPMENT_TEAM`. See [docs/packaging.md](docs/packaging.md) before creating or submitting distribution artifacts.

The default checks do not run model inference, start Hermes, request microphone access, or launch the app.

## Resource use and settings

Settings has General, Models, Voice & speech, Appearance, and Advanced pages. Changes save automatically. Appearance, orb visibility, agent models, typed replies, transcript history, and hotkeys apply without restarting the speech runtime. Voice and endpoint changes reuse the loaded Parakeet model when its path, compute units, and capture profile are unchanged.

The Appearance page includes Automatic, Save energy, and Smooth motion animation choices. Automatic targets 30 fps during a run and 10 fps while idle, dropping to 15 and 5 fps in macOS Low Power Mode. Smooth motion targets 60 fps during a run. Hidden floating orbs release their view and renderer, unselected previews are static, and Reduce Motion stops continuous rendering.

Streamed text updates are coalesced at roughly 30 updates per second; tool and approval events publish immediately. Interrupting or stopping a turn cancels the SSE consumer and its network producer. Use the Stop button or Escape to cancel listening, tool activity, and speech while keeping the partial answer visible. Each response also has a Copy button.

Recordings automatically submit at two minutes, capping the mono 16 kHz capture buffer at 1,920,000 samples. Conversion buffers are reused, and microphone visual updates run at most 30 times per second. Conversation context retains the newest 12 exchanges within a 24,000-character budget. Transcript history retains its separate 50-turn limit. Both keep the existing five-minute expiration.

## Hermes runtime

Hermes exposes the HTTP/SSE run API through its `api_server` gateway platform. `hermes serve` is the desktop JSON-RPC/WebSocket backend and is not the endpoint J.A.R.V.I.S. uses.

J.A.R.V.I.S. uses the dedicated Hermes profile at `~/.hermes/profiles/jarvis` and owns the managed endpoint `http://127.0.0.1:8643`. When needed, the app launches `hermes -p jarvis gateway run --force --external-supervisor`; it never changes Hermes's sticky active profile. `--force` opts this app-owned, API-only profile out of Hermes's host-gateway multiplexing policy. The generated bearer key is stored in macOS Keychain and passed only through the child-process environment together with the managed listener host and port. Hermes launch failures report the child exit status and captured output instead of waiting for the startup deadline.

The managed endpoint is accepted only when the current app instance owns the Hermes process and authenticated `/v1/capabilities` confirms the required run/SSE/stop/approval API. A pre-existing listener on port 8643 is reported as occupied and unverified instead of being silently reused. A non-default loopback endpoint configured with `JARVIS_HERMES_BASE_URL` or in Settings is operator-managed: the app does not launch Hermes there, and the operator is responsible for ensuring it serves the `jarvis` profile. Current Hermes capability payloads authenticate API compatibility but do not attest the named profile.

Development overrides remain available through `JARVIS_HERMES_BASE_URL`, `JARVIS_HERMES_API_KEY`, and `JARVIS_HERMES_EXECUTABLE`. The `jarvis` profile must not define `API_SERVER_ENABLED`, `API_SERVER_HOST`, `API_SERVER_PORT`, or `API_SERVER_KEY` in its `.env` or API-server configuration because the app-owned child environment is authoritative. See [docs/hermes-profile.md](docs/hermes-profile.md) for the profile, parity, and trust contract.

## Focused diagnostics

```bash
swift run --package-path apps/macos JarvisDiagnostics parakeet /path/to/audio.wav
swift run --package-path apps/macos JarvisDiagnostics parakeet-reuse /path/to/audio.wav
swift run --package-path apps/macos JarvisDiagnostics hermes
swift run --package-path apps/macos JarvisDiagnostics hermes-session
swift run --package-path apps/macos JarvisDiagnostics hermes-tool
swift run --package-path apps/macos JarvisDiagnostics hermes-stop
swift run --package-path apps/macos JarvisDiagnostics tts-voices
swift run --package-path apps/macos JarvisDiagnostics tts-cancel
swift run --package-path apps/macos JarvisDiagnostics deepgram-stt /path/to/audio.wav
swift run --package-path apps/macos JarvisDiagnostics deepgram-tts "Diagnostic sentence"
```

The Deepgram diagnostics require a user-provided Keychain credential and may incur provider usage. They are never run by the default build or test commands.

Phase 2 includes native Deepgram STT/TTS, consent-gated local/cloud/auto routing, immediate settings application, quiet/normal/noisy capture profiles, Keychain-backed credentials, opt-in bounded transcript persistence, tool and approval UI, provider health/fallback status, content-free latency metrics, and new-conversation controls.

Phase 3 adds sleep/wake, microphone-permission, audio-device, network, and owned-Hermes-process recovery; bounded restart policies; visible runtime health; packaged-app launch-at-login support; content-free barge-in metrics; and bounded privacy-safe diagnostics.

Phase 4 implementation is complete: the project has a native Xcode application/archive target, pinned Parakeet source without development-path build dependencies, external model/Hermes validation, hardened-runtime signing, Developer ID export support, guarded notarization/stapling, ZIP/DMG generation, and installed-bundle validation. Running the final Developer ID/notary and physical clean-account checks still requires the release owner's Apple credentials and installed test environment.

See [PLAN.md](PLAN.md), [docs/phase-0-status.md](docs/phase-0-status.md), [docs/phase-1-status.md](docs/phase-1-status.md), [docs/phase-2-status.md](docs/phase-2-status.md), [docs/phase-3-status.md](docs/phase-3-status.md), and [docs/phase-4-status.md](docs/phase-4-status.md).

## Models, settings, and updates

Settings save and apply automatically after a short pause in editing. Changes are queued while an application is in progress, and invalid entries show an error while the last working configuration remains saved. Liquid Glass is the only voice orb; old orb selections and shuffle options are ignored when loading older preferences.

The **Models** pane loads Hermes's configured provider catalog and lets you choose a provider and model, or enter custom IDs. Empty fields follow Hermes's defaults. Choices apply to the next Jarvis request without changing Hermes CLI or desktop settings or reloading speech models.

Jarvis includes Sparkle updates and a GitHub Actions release pipeline. Personal releases work without a paid Apple developer account and use the configured Ed25519 update key. Apple Developer ID signing and notarization are optional. The repository is public after a [secret audit](docs/repository-secret-audit.md). See [update setup and release instructions](docs/updates.md) for the one-time installation of the first build containing the updater and macOS approval for personal builds.
