# Dedicated Hermes profile

J.A.R.V.I.S. uses the named Hermes profile `jarvis` at `~/.hermes/profiles/jarvis`.

## Runtime contract

- Managed profile: `jarvis`
- Managed endpoint: `http://127.0.0.1:8643`
- Managed launch: `hermes -p jarvis gateway run --force --external-supervisor`
- Profile multiplexing: disabled
- Listener enabled/host/port/key source: app child-process environment
- Bearer key source: macOS Keychain through `InstallationIdentity`

The app never runs `hermes profile use jarvis`. Port 8642 remains available to the general/default Hermes gateway. Hermes 0.21.5 refuses a separate named-profile gateway without `--force`; this flag explicitly keeps the app-owned API listener separate. `--external-supervisor` returns restarts to the app instead of leaving a detached gateway process behind.

A listener already present on port 8643 is verified against the dedicated profile's `gateway.pid` record. The record must identify a `hermes-gateway` launched with `--external-supervisor`, name the exact profile directory, and match the live process's PID, start time, current OS user, and exclusive TCP listener. Missing, malformed, legacy, mismatched, or ambiguous records fail closed. Readiness also uses authenticated `/v1/capabilities` and verifies the run, SSE, status, stop, and approval API contract.

A verified compatible gateway is reused after an app crash or update and monitored for exit. If it rejects the current key or has an incompatible API, only a verified orphan whose parent is PID 1 can be stopped and relaunched. Identity is rechecked before each signal, with a bounded graceful stop followed by forced termination if needed. A gateway belonging to another live app is never stopped. Shutdown detaches from reused gateways; it cancels pending startup and waits for an owned child to exit. Concurrent startup requests share one launch.

A non-default loopback endpoint is operator-managed. J.A.R.V.I.S. does not auto-launch Hermes there. The endpoint must accept the configured bearer key and expose the compatible API, while the operator remains responsible for ensuring it serves the `jarvis` profile because Hermes's capability payload does not attest named-profile identity.

## Profile contents

`SOUL.md` contains the compact J.A.R.V.I.S. identity. `memories/USER.md` and `memories/MEMORY.md` began empty and are mutable, bounded Hermes memory stores. Capability and permission configuration remains in `config.yaml`, `.env`, credential stores, skills, and plugins rather than prompt files.

The profile manifest is stored at:

```text
~/.hermes/profiles/jarvis/jarvis-profile-manifest.json
```

The parity check is:

```bash
~/.hermes/profiles/jarvis/scripts/check-profile-parity.sh
```

Static parity compares normalized configuration, managed-listener conflicts, memory flags, skills and their content hashes, profile plugins, identity drift, and the manifest. Runtime parity was reviewed against authenticated `/v1/capabilities`, `/v1/skills`, and `/v1/toolsets` responses. Desktop/TUI presentation tools such as `read_terminal` and `open_preview` are intentionally excluded from API-only gateway parity.

The named profile currently resolves configured provider credentials through Hermes's per-provider global `~/.hermes/auth.json` fallback. This is intentional capability parity, not credential isolation, and must be reviewed if provider configuration changes.

## Updating the profile

Re-run the parity check after Hermes upgrades or changes to configuration, providers, credential sources, skills, MCP servers, plugins, permissions, memory flags, or gateway topology. Changes to `SOUL.md`, newly added capabilities, less restrictive permission settings, or new credential-source fallbacks require explicit review. USER and MEMORY hashes are review snapshots and are not immutable drift gates.
