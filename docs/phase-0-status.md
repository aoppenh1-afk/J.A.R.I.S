# Phase 0 Native Pivot Status

## Implemented

- Fully native Swift package with `JarvisCore` and `JarvisApp` targets.
- SwiftUI menu-bar popover and native assistant state UI.
- Carbon press/release event mapping for true push-to-talk.
- AVAudioEngine capture and conversion to mono 16 kHz floats.
- Direct in-process Parakeet model loading and transcription adapter.
- Native AVSpeechSynthesizer playback and immediate cancellation.
- URLSession Hermes client for health, capabilities, runs, SSE, approvals, stop, and reconciliation.
- Generation-gated actor pipeline for transcription, Hermes events, approvals, TTS, and barge-in.
- Focused tests for configuration privacy, generation invalidation, SSE, sentence buffering, and hotkey event mapping.
- Electron, React, Node, Python, Pipecat, Voice UI Kit, WebRTC, and IPC-helper code removed.

## Explicit live gates not run

1. Launch the menu-bar application and approve microphone access.
2. Validate Carbon global hotkey behavior while another app or Space is active.
3. Benchmark Parakeet CPU/GPU/ANE/all and confirm transcription quality.
4. Start Hermes and validate tools, approvals, sessions, memory, and cancellation.
5. Measure AVSpeechSynthesizer cancellation and end-to-end barge-in latency.
6. Complete repeated real microphone turns and audio-device changes.

The default check builds/tests Swift code only; it does not launch the app or run model/Hermes inference.
