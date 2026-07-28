# Native Architecture

J.A.R.V.I.S. is a single native macOS process for v1.

## Components

- `MenuBarExtra` and SwiftUI own the assistant popover, status, transcript, tools, and approvals.
- Carbon hotkey events provide distinct key-down and key-up callbacks for global push-to-talk.
- `AVAudioEngine` captures microphone audio and `AVAudioConverter` normalizes it to mono 16 kHz floats.
- `ParakeetRecognizer` loads the existing Core ML model directly and retains it across turns.
- `HermesClient` uses URLSession for health, runs, SSE, approvals, status reconciliation, and stop.
- `MacSpeechSynthesizer` uses direct native playback and immediate cancellation.
- `VoicePipeline` is an actor that owns turn state and generation invalidation.

## Why Pipecat is not in v1

Pipecat is valuable for browser/WebRTC, phone, remote, multi-user, or cross-platform channels. A local single-user macOS assistant does not need a Python voice server, audio IPC, or WebRTC. Protocol boundaries remain in `JarvisCore` so a future remote/Pipecat channel can be added without replacing the native app.

## Trust boundaries

Hermes defaults to loopback. API keys and the stable memory key move to Keychain before release. Local mode never constructs a cloud speech provider. Hermes event text is treated as untrusted display data.
