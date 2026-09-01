# Arcadia NPC AI Gateway

This private service separates DreamDaemon from model providers. Dream Maker sends a bounded
perception snapshot and server-generated capability IDs; the gateway asks the configured model to
select one ID. DreamDaemon remains authoritative and revalidates the action before execution.

## Local mock test

```powershell
$env:ARCADIA_NPC_PROVIDER = "mock"
$env:ARCADIA_NPC_GATEWAY_TOKEN = "replace-with-a-local-secret"
py -3 tools\npc_ai_gateway\gateway.py
```

Configure the game server:

```ini
NPC_AI_ENABLED TRUE
NPC_AI_GATEWAY_URL http://127.0.0.1:8787/v1/decide
NPC_AI_GATEWAY_TOKEN replace-with-a-local-secret
```

The mock provider always selects a safe wait action. It exercises HTTP, queueing, stale-response
protection, and persistence without using a model or spending API credits.

## Luna/OpenAI

Set the provider API key only in the gateway process environment:

```powershell
$env:ARCADIA_NPC_PROVIDER = "openai"
$env:OPENAI_API_KEY = "your-provider-key"
$env:ARCADIA_NPC_GATEWAY_TOKEN = "a-different-private-gateway-secret"
py -3 tools\npc_ai_gateway\gateway.py
```

The default model for tiers L1-L3 is `gpt-5.6-luna`. Override it with
`ARCADIA_NPC_MODEL_L1`, `ARCADIA_NPC_MODEL_L2`, or `ARCADIA_NPC_MODEL_L3`.
The implementation uses the OpenAI Responses API with strict Structured Outputs.

Never put `OPENAI_API_KEY` in Dream Maker configuration or commit it to the repository. The
`NPC_AI_GATEWAY_TOKEN` authenticates DreamDaemon to this private service; it is not an OpenAI key.
Keep the gateway bound to loopback or a protected private network. A non-loopback bind is rejected
at startup unless `ARCADIA_NPC_GATEWAY_TOKEN` is configured.

## Persistence and operations

Long-lived episodic memory is stored by default in
`tools/npc_ai_gateway/data/npc_memory.sqlite3`, which is ignored by Git. Canonical biography and
character constraints remain authored in Arcadia and are sent on every decision.

Useful environment variables:

- `ARCADIA_NPC_HOST` and `ARCADIA_NPC_PORT`: bind address, default `127.0.0.1:8787`.
- `ARCADIA_NPC_DATABASE`: SQLite path.
- `ARCADIA_NPC_MEMORY_LIMIT_PER_ACTOR`: retained memories, default 200.
- `ARCADIA_NPC_OPENAI_TIMEOUT_SECONDS`: provider timeout, default 12.
- `ARCADIA_NPC_MAX_CONCURRENT_REQUESTS`: simultaneous provider calls, default 8.
- `ARCADIA_NPC_MAX_REQUESTS_PER_MINUTE`: gateway-wide provider-attempt budget, default 120.
- `ARCADIA_NPC_RETRY_ATTEMPTS`: retries after a transient provider failure, default 2.
- `ARCADIA_NPC_RETRY_BASE_DELAY_SECONDS`: exponential-backoff base, default 0.25.
- `ARCADIA_NPC_CIRCUIT_FAILURE_THRESHOLD`: transient failures before opening the circuit, default 5.
- `ARCADIA_NPC_CIRCUIT_OPEN_SECONDS`: circuit cooldown, default 30.
- `OPENAI_BASE_URL`: provider-compatible Responses API base URL.

Health check: `GET /healthz`. Authenticated operational counters: `GET /metrics`.
Decision endpoint: `POST /v1/decide`.
Logs contain request IDs, actor IDs, selected action kinds, model names, and latency. They do not
contain API keys, full prompts, player speech, biographies, or model output text.

Run gateway tests:

```powershell
py -3 -m unittest discover -s tools\npc_ai_gateway -p "test_*.py"
```

Run the live dialogue regression scenarios only when API usage is intended:

```powershell
$env:ARCADIA_NPC_PROVIDER = "openai"
$env:OPENAI_API_KEY = "your-provider-key"
py -3 tools\npc_ai_gateway\dialogue_eval.py --live
```

The live evaluator prints scenario speech deliberately for reviewer inspection. Normal gateway
request logs remain metadata-only and never contain player dialogue or model output.
