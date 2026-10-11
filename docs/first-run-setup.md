# First-run setup

J.A.R.V.I.S. opens setup on first launch. Closing it with Later keeps setup pending and leaves voice and typed submission disabled. Reopen it with Complete setup in the popover, or Set up J.A.R.V.I.S. in the More menu. Existing installations see setup once when they first run a build containing this flow.

## Hermes

Install the [Hermes command-line app](https://hermes-agent.nousresearch.com/docs/getting-started/installation/). The app looks in `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`, or at `JARVIS_HERMES_EXECUTABLE` when supplied for development.

Create and configure the dedicated profile in Terminal. Skip creation if it already exists:

```sh
hermes profile create jarvis
hermes -p jarvis setup
```

Use Hermes setup to configure your provider and model. The [Hermes profile guide](https://hermes-agent.nousresearch.com/docs/user-guide/profiles/) explains named profiles. These commands do not switch Hermes's sticky active profile.

Click Check again after installing or configuring Hermes. Setup checks that the launcher is available and the profile configuration is readable. Starting then verifies authenticated API compatibility. These checks do not submit a paid model request or prove that provider credentials work.

Keep the default `http://127.0.0.1:8643` to let J.A.R.V.I.S. supervise Hermes. For a custom loopback endpoint, start the compatible API yourself. All endpoints and redirects must use HTTP or HTTPS on `127.0.0.1`, `localhost`, or `::1`, without credentials embedded in the URL. See [the profile/runtime contract](hermes-profile.md) for listener configuration and occupied-port errors.

## Speech

Local is the default. Choose an existing [Parakeet Core ML model](https://huggingface.co/mweinbach1/parakeet-tdt-0.6b-v3-coreml) folder, or click Download model. The button downloads to `~/Library/Caches/com.parakeet-tdt/hf-models/mweinbach1_parakeet-tdt-0.6b-v3-coreml`. Downloads can be cancelled and are never started automatically.

The folder must contain the encoder, decoder, and joint `.mlpackage` manifests, models, and weights, plus `tokenizer.json`. Checks reject missing, empty, unreadable, or non-file assets and accept readable cache symlinks. The Core ML model is actually loaded when you click Start J.A.R.V.I.S.; invalid model contents keep setup open with an error.

Cloud requires a Deepgram API key. Auto can proceed without a complete local model only when cloud fallback is explicitly enabled and a key is provided. Audio is sent to Deepgram only under that selected routing policy. Setup stores the key in Keychain as part of applying the configuration and restores the prior key if preparation fails.

## Microphone and completion

Allow microphone triggers the macOS permission request. If permission is denied, use Open microphone settings. You can start without microphone access and use typed messages, then enable access from the popover later.

Start J.A.R.V.I.S. loads speech and verifies Hermes before saving the preferences and completion flag. Startup failures keep setup pending. A later launch that cannot prepare its runtime reopens setup with the failure visible in the popover.

## Validation

`swift test --package-path apps/macos` checks prerequisite combinations, incomplete model folders and cache symlinks, blocked model-discovery drafts, all authenticated client routes, redirect policy, ready-then-crash rate limiting, and stale reconciliation after interruption. The process test launches only a temporary shell fixture. Tests do not download models, run inference, request microphone access, or call real Hermes/provider services.
