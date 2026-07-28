# Phase 2 Status

## Completed

- Native Deepgram prerecorded STT using Nova-3, authenticated WAV upload, smart formatting, timeout/error propagation, and local silence rejection.
- Native Deepgram Aura-2 TTS using linear PCM WAV audio, native playback, and context cancellation.
- Local, cloud, and auto routing with explicit cloud-fallback consent.
- Local mode does not construct or invoke Deepgram providers. Auto mode remains local-first and does not duplicate or race requests.
- Deepgram, Hermes bearer, and Hermes session credentials are stored in macOS Keychain rather than source or UserDefaults.
- Non-secret settings persist for speech mode, fallback consent, push-to-talk hotkey preset, capture profile, Parakeet model and compute units, macOS voice, Deepgram models, Hermes endpoint, and transcript retention.
- Settings are applied immediately without restarting. Runtime replacement cancels active capture, validates the candidate providers and Hermes endpoint, reuses an unchanged owned Hermes server, and preserves the previous runtime if activation fails.
- Quiet, normal, and noisy capture profiles apply progressively stricter RMS silence thresholds before local inference or cloud upload.
- Content-free per-turn metrics report STT latency, Hermes first-delta latency, Hermes completion latency, and the point at which TTS was queued. Metrics do not store transcript text.
- Bounded provider health records cloud success/failure state, caps failure state after three consecutive failures, and displays auto-fallback reasons.
- Transcript history is bounded to 50 completed turns. Persistence is opt-in and disabled by default; otherwise history remains memory-only. Clearing history deletes the persisted copy.
- The popover includes provider identity, tool activity rows, tool success/failure state, explicit approval cards, fallback status, provider health, latency diagnostics, new-conversation control, and clear-history control.
- Live Deepgram diagnostics are available as explicit commands and run only when a user-provided Keychain credential exists:

```bash
swift run --package-path apps/macos JarvisDiagnostics deepgram-stt /path/to/audio.wav
swift run --package-path apps/macos JarvisDiagnostics deepgram-tts "Diagnostic sentence"
```

These commands are not part of the default test/build path and may incur Deepgram usage.

## Privacy and routing guarantees

- `local`: Parakeet STT and macOS TTS only. Deepgram providers are not constructed.
- `cloud`: Deepgram is required and missing credentials/provider state fail visibly.
- `auto`: local-first. Deepgram fallback requires both an explicit setting and a configured key.
- Silence is rejected before any Deepgram request.
- Provider requests are sequential, never raced, and an ambiguous timeout is not retried automatically.
- Local speech mode controls the speech boundary only; Hermes may still use whatever reasoning model is configured in Hermes.
- Transcript persistence is disabled by default and is separate from content-free latency/provider metrics.

## Verification

- 38 XCTest tests pass with 0 failures.
- Deepgram STT tests cover authentication, WAV construction, model selection, response decoding, HTTP errors, malformed responses, timeout propagation without retry, missing credentials, and zero requests for silence.
- Deepgram TTS tests cover request construction, Aura model and WAV parameters, valid WAV playback, HTTP errors, malformed audio, timeout propagation without retry, missing credentials, and context cancellation.
- Routing tests cover local-only privacy, cloud-unavailable behavior, consent-gated fallback, fallback reporting, and bounded provider health.
- Capture-profile tests verify increasing noise thresholds.
- History tests verify the 50-turn retention boundary and persisted-history deletion.
- Existing Hermes SSE, generation invalidation, hotkey, sentence buffering, streaming TTS, configuration, and WAV tests continue to pass.
- Debug and release package builds pass without launching the app, loading the Parakeet model, starting Hermes, using the microphone, or making paid Deepgram requests.

## Manual checks still appropriate before distribution

Phase 2 implementation is complete. Physical-device and account-dependent checks remain release validation rather than missing Phase 2 code:

- Confirm microphone permission and global hotkey behavior under the packaged app identity.
- Exercise live Deepgram STT/TTS with the user's own credential if desired.
- Verify preferred macOS and Deepgram voices on the target audio device.
- Exercise an actual Hermes policy that emits `approval.request`; the currently observed isolated policy may auto-execute permitted commands.
