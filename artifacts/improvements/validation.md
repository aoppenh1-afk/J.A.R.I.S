# Improvement validation

- Swift tests: 115 passed, 0 failures.
- Swift release build: passed.
- Local app bundle: `dist/improvements/J.A.R.V.I.S.app`, ad hoc signed for local validation.
- Bundle validation: Info.plist, arm64 executable, hardened runtime, audio/network entitlements, bundled glass renderer resources, and system framework linkage checked.
- Native settings: rendered the actual SettingsView in a temporary SwiftUI app without creating AppModel, starting Hermes, or capturing audio. Inspected Voice & speech and Appearance pages and category navigation. Preview app was then closed and removed.
- Glass renderer browser checks: static mode and Reduce Motion generated zero continuous frames after settling; simulated hidden-document state generated zero frames. A 15 fps target held at 13 measured frames per second while receiving 100 state updates per second. The browser test is not a battery benchmark.
- Full microphone/model/Hermes integration and physical battery measurements were not performed. The installed running app was not replaced.

## Changes

Hidden orb views are removed; animation follows a saved quality setting and Low Power Mode. Native and WebGL animation honor Reduce Motion. Speech models survive cosmetic changes and can be reused across voice/endpoint changes. Microphone conversion buffers are reused, visual signals are capped at 30 updates per second, silence submission uses one deadline task, and recordings submit at 120 seconds. Context is limited to 12 recent exchanges and 24,000 characters. Text snapshots coalesce at about 30 updates per second while tool and approval events remain immediate. Stream and speech cancellation are covered by regression tests. Settings is divided into four pages with a fixed Save/Revert footer and validation before persistence. Responses have Copy controls and a Stop/Escape action.

Automatic animation uses Apple's power-state notification and `isLowPowerModeEnabled`, documented in [Apple Foundation documentation](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/nsprocessinfopowerstatedidchange).
