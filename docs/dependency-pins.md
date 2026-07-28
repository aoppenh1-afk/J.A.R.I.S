# Dependency Pins

The native app deliberately minimizes third-party dependencies.

| Dependency | Current source | Purpose |
|---|---|---|
| Parakeet Core ML Swift | Vendored source snapshot `f71daf2dbcccf88aed2d49fdb308e50fba643389` under `apps/macos/Vendor/ParakeetTDT` | On-device STT |
| Apple SwiftUI/AppKit | macOS SDK | Menu-bar application and native UI |
| AVFoundation | macOS SDK | Microphone capture, conversion, and TTS |
| Carbon HIToolbox | macOS SDK | Global key-down/key-up hotkey events |
| Foundation URLSession | macOS SDK | Hermes HTTP and SSE |

The Parakeet library source is pinned and self-contained for clean release builds. Its Apache-2.0 license and snapshot provenance are retained in `apps/macos/Vendor/ParakeetTDT`. Core ML model weights remain external and are not distributed with the app.
