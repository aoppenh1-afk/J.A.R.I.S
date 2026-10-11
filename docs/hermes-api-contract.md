# Hermes HTTP Contract

The native Swift client targets the installed Hermes loopback API. In Hermes 0.19.0 this API is provided by the `api_server` gateway platform, not by `hermes serve` (the desktop JSON-RPC/WebSocket backend). The gateway requires bearer authentication even on loopback. J.A.R.V.I.S. stores a generated key in Keychain, automatically launches or attaches to the gateway, and supports `JARVIS_HERMES_API_KEY` as a development override.

## Endpoints

- `GET /health`
- `GET /v1/capabilities`
- `GET /api/model/options` (native provider/model catalog)
- `POST /v1/runs`
- `GET /v1/runs/{run_id}`
- `GET /v1/runs/{run_id}/events`
- `POST /v1/runs/{run_id}/approval`
- `POST /v1/runs/{run_id}/stop`

## SSE events

- `message.delta`
- `tool.started` / `tool.completed`
- `reasoning.available`
- `approval.request` / `approval.responded`
- `run.completed` / `run.failed` / `run.cancelled`

`HermesClient` uses URLSession and `SSEParser`. Hermes emits one JSON object per SSE `data:` line; the client handles Foundation builds that omit empty separator lines. The `error` field is decoded as either a terminal error string or the boolean failure flag used by `tool.completed`. If the stream closes without a terminal event, `VoicePipeline` queries run status once and never replays the user turn automatically.

Barge-in increments the local generation before calling `/stop`, ensuring late Hermes events cannot reach native UI or speech playback.

## Model selection

Jarvis sends optional `provider` and `model` strings in `POST /v1/runs`. Empty preferences omit those fields and follow Hermes’s defaults. Selections apply to subsequent runs without editing the profile configuration or interrupting an existing run. `/api/model/options` supplies the native authenticated provider inventory, current defaults, and unavailable model IDs; `/v1/models` supplies OpenAI-compatible aliases and is not the native picker catalog. Custom IDs remain available when discovery fails. The connected Hermes installation must support these native endpoints and request overrides.
