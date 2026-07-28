# Phase 3 Status

## Completed

- Registered for macOS sleep and wake notifications through `NSWorkspace`.
- Sleep cancels microphone capture, invalidates the active generation, stops speech, requests active Hermes-run cancellation, and clears stale approval state.
- Wake performs bounded readiness recovery for Hermes, speech providers, audio state, and the global hotkey. Interrupted audio and utterances are never replayed.
- Registered for `AVAudioEngineConfigurationChange`; input-device changes cancel the current turn and trigger debounced recovery.
- Added runtime microphone-authorization checks when the app becomes active and before push-to-talk can begin.
- Permission revocation stops active capture and voice state, marks microphone health unavailable, and exposes an Open Microphone Privacy Settings action.
- Permission restoration triggers normal runtime readiness recovery.
- Added explicit audio errors for a missing default input device, zero-channel formats, zero/non-finite sample rates, conversion setup, and buffer failures.
- Failed `AVAudioEngine.start()` calls now remove the installed tap and reset conversion state before returning an error.
- Added `NWPathMonitor` connectivity state. Network loss is visible, and restoration triggers recovery without changing speech mode or cloud-fallback consent.
- Added Network, Hermes, Audio, and Microphone health indicators to the popover.
- Added a bounded runtime recovery policy with three attempts and fixed delays of 0 ms, 500 ms, and 2 seconds.
- Added owned-Hermes-process termination observation. Unexpected exits immediately mark Hermes unavailable and start bounded recovery.
- Added Hermes process accounting for total starts, unexpected exits, last exit status, and owned-process state.
- Added a restart limiter allowing at most three Hermes starts in a rolling 60-second window.
- Intentional Hermes shutdown and runtime replacement do not count as unexpected exits or trigger restarts.
- Added `SMAppService.mainApp` launch-at-login integration. The control is enabled only for a packaged `.app`; SwiftPM development executables explain why it is unavailable.
- Added a 200-entry in-memory diagnostic ring buffer with typed events only. Events contain timestamp, event kind, and optional recovery-attempt number—never transcript text, prompts, responses, arbitrary errors, paths, or credentials.
- Added content-free capture-duration and barge-in latency measurements. They appear as `Audio … ms` and `Stop … ms` in turn diagnostics.

## Privacy and recovery guarantees

- Recovery never changes local/cloud/auto speech mode or cloud-fallback consent.
- Local mode never constructs a Deepgram provider during initial startup or recovery.
- Failed, timed-out, interrupted, or sleeping turns are never automatically submitted again.
- Sleep, device changes, permission revocation, network restoration, and Hermes exits invalidate active turn state before reuse.
- Diagnostic events are bounded and memory-only. They are cleared on process exit or through the popover.
- Hermes auto-start remains loopback-only and J.A.R.V.I.S. only terminates processes it owns.
- Restart throttling applies only to Hermes process startup; it does not retry or duplicate user utterances.

## Verification

- 47 XCTest tests pass with 0 failures.
- Recovery-policy tests verify bounded attempts and delays.
- Hermes restart-limiter tests verify burst rejection and recovery after the rolling window expires.
- Audio-format tests verify usable formats and reject zero-channel, zero-rate, and non-finite formats.
- Barge-in tests verify interruption latency is recorded without retaining user or assistant text in the new turn snapshot.
- Diagnostic-buffer tests verify retention bounds and prove the encoded schema has no transcript, arbitrary error, or API-key fields.
- The release package build passes.
- Automated verification does not launch the app, request microphone access, run Parakeet inference, start Hermes, or make Deepgram requests.

## Manual release validation

Phase 3 implementation is complete. These checks require physical macOS state or a packaged application and therefore remain release validation rather than missing implementation:

- Revoke and restore microphone permission in System Settings while J.A.R.V.I.S. is open.
- Sleep and wake during capture, Hermes generation, approval, and speech playback.
- Disconnect and reconnect built-in, wired, USB, and Bluetooth input/output devices.
- Transition between online, offline, and captive-network states.
- Terminate an owned Hermes process and confirm bounded restart behavior.
- Confirm launch-at-login using the signed application bundle produced in Phase 4.
- Measure audible barge-in on target hardware and compare it with the content-free `Stop` metric.
