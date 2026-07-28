# Phase 1 Status

## Implemented

- Stable Hermes installation/session identity stored in macOS Keychain, with a `UserDefaults` fallback only when Keychain writes fail.
- Sentence-safe Hermes delta buffering and sequential native TTS playback before the run completes.
- Barge-in cancellation of the active utterance, queued sentences, and Hermes run, with generation-gated stale event rejection.
- Configurable native TTS voice identifier, rate, and pitch.
- Silence gating before Parakeet inference to prevent the installed model from hallucinating on empty audio.
- Automatic attachment to a healthy Hermes API or launch of an owned `hermes gateway run` process when no API is available.
- A random Hermes API bearer key stored in macOS Keychain and passed only through the child-process environment.
- Environment-based Hermes endpoint, executable, and API-key overrides without checking secrets into the repository.
- Graceful shutdown of the Hermes process owned by J.A.R.V.I.S., plus an explicit Quit action in the menu-bar UI.
- A native `JarvisDiagnostics` executable for Parakeet, Hermes, and TTS checks.
- Hermes SSE compatibility for URLSession builds that omit blank separator lines.
- Flexible decoding for Hermes `tool.completed.error`, which is a boolean while terminal run errors are strings.

## Measurements

Measured on July 27, 2026 using a 3.8044-second macOS-generated speech fixture:

| Core ML mode | Model load | Inference | RTFx | Transcript |
| --- | ---: | ---: | ---: | --- |
| CPU | 5.0959 s | 4.7021 s | 0.8091 | Incorrect repetitive output |
| GPU | 4.2084 s | 0.6474 s | 5.8766 | Correct |
| ANE | 16.0890 s | 0.1839 s | 20.6826 | Correct |
| All | 17.5945 s | 0.2226 s | 17.0915 | Correct |

ANE is now the default because the model remains loaded across turns and ANE had the lowest steady-state inference latency. Its slower one-time load remains visible during startup.

Ten consecutive transcriptions reused one ANE transcriber instance. All ten transcripts were correct, with average inference latency of 0.1713 seconds.

Quality checks:

- Short two-second fixture: recognized `Jarvis.`
- Noisy fixture: degraded but recognizable output.
- Silent fixture: the raw model hallucinated `Yeah.`; the application now rejects the same signal before inference using an RMS silence gate.

Native TTS cancellation returned in 0.0002 seconds, below the 250 ms barge-in target. This measures the synthesizer stop/continuation path; audible end-to-end barge-in still needs a manual app check.

## Hermes validation

The installed Hermes version is `0.19.0`. `hermes serve` runs the desktop JSON-RPC/WebSocket backend on port 9119; it is not the HTTP run API. The HTTP/SSE API is the `api_server` gateway platform and was validated on loopback port 8642 with a temporary bearer key.

Validated:

- `GET /health`
- `GET /v1/capabilities`
- `POST /v1/runs`
- SSE `message.delta`, `reasoning.available`, and `run.completed`
- `tool.started` and `tool.completed`
- same-session continuity across two separate native client instances
- `POST /v1/runs/{run_id}/stop` (31.9 ms request latency; reconciled status was `stopping` immediately afterward)

Automatic gateway startup was validated from both `JarvisDiagnostics` and the running menu-bar application. The app-managed endpoint passed health, capability, SSE, and inference checks without manually starting Hermes in a terminal.

Approval transport is implemented, but the isolated validation gateway auto-executed both tested terminal commands and emitted no `approval.request`. Approval behavior therefore remains an external Hermes policy/configuration gate rather than a passed live check.

## Automated verification

- 12 XCTest tests pass.
- Streaming TTS is tested to begin after a complete sentence and before `run.completed`.
- Silence gating, boolean Hermes tool errors, generation invalidation, SSE parsing, configuration privacy, sentence buffering, and hotkey event mapping are covered.

## Remaining manual gates

The development menu-bar executable launched successfully, advanced through microphone authorization, automatically started Hermes, and completed an app-managed Hermes inference check. The remaining items require physical audio or a Hermes policy change rather than more Phase 1 implementation:

1. Speak through a real input device and verify the captured transcript.
2. Verify the global hotkey press/release behavior while another application and macOS Space are active.
3. Run ten complete microphone → Parakeet → Hermes → TTS turns in the menu-bar app.
4. Measure audible hotkey-to-silence barge-in latency, not only the synthesizer cancellation call.
5. Validate an actual `approval.request` after Hermes is configured with a policy that requires approval.

These checks must be repeated under the final signed application identity during Phase 4 because macOS permissions are identity-specific.
