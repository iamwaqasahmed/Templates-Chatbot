# M6 — Core Chat API v1 (Stateless, Streaming-Ready, Production Contracts) — Technical Design v1

M6 delivers the first production-grade API service for chat, designed to scale horizontally behind ALB/CloudFront and handle thousands of concurrent streaming connections. It is stateless, secure, and has stable contracts (request/response schemas, error taxonomy, tracing/logging, and runtime limits).

M6 is intentionally **provider-agnostic**: OpenAI / Bedrock / Anthropic can be plugged in later without changing public API contracts.

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- A **FastAPI** service that supports:
  - Authenticated requests (JWT verified, M4)
  - **SSE streaming** for chat responses
  - Non-stream fallback response
  - Health/readiness endpoints
  - Structured logs, metrics, tracing
- **Strict input validation** + stable request schemas
- **Runtime safety controls:** timeouts, max concurrency, payload limits, backpressure

### Non-goals (next milestones)

- Durable conversation persistence (M7)
- Redis rate limiting (M8)
- ECS/ALB scaling and production deploy (M9)
- Tools/plugins framework (M13)
- RAG (M14)

### Outcomes

- Local + containerized API runs with: `/health`, `/ready`, `/v1/chat` (non-stream), `/v1/chat/stream` (SSE)
- Strong error model + request IDs + tracing
- Concurrency-safe streaming architecture

---

## 2. Service Architecture (inside `services/chat-api`)

### 2.1 Layering (clean separation)

```
api (routers) → auth (JWT) → orchestrator → llm_provider → stream_writer
                               ↓
                           policies (limits, timeouts)
```

### Modules

| Path | Purpose |
|------|---------|
| `app/main.py` | App factory + middleware |
| `app/api/routes_chat.py` | Endpoints |
| `app/core/auth.py` | JWT verification + AuthContext |
| `app/core/config.py` | Typed settings |
| `app/core/errors.py` | Error taxonomy |
| `app/core/logging.py` | JSON logs + correlation IDs |
| `app/core/telemetry.py` | Metrics + tracing hooks |
| `app/services/orchestrator.py` | Builds prompt/messages and streams output |
| `app/providers/base.py` | LLMProvider interface |
| `app/providers/openai.py` / `bedrock.py` | Optional implementations |
| `app/utils/sse.py` | SSE helpers |

### 2.2 Statelessness rule

No in-memory session state required for correctness. A single request contains everything needed to respond (temporary in-memory streaming buffer is fine).

---

## 3. Public API Contract (v1)

### 3.1 Common requirements

- All endpoints require **`Authorization: Bearer <access_token>`**
- Response headers always include: **X-Request-Id**; **Cache-Control: no-store** on API responses

### 3.2 Data models (Pydantic schemas)

**ChatMessage**

```json
{
  "role": "user|assistant|system",
  "content": "string"
}
```

**ChatRequest**

```json
{
  "conversation_id": "string (optional in M6; required in M7)",
  "messages": [ChatMessage],
  "model": "string (optional)",
  "temperature": 0.7,
  "max_output_tokens": 512,
  "metadata": { "any": "json" }
}
```

**Constraints (hard limits in M6)**

- `messages.length` ≤ 50 (configurable)
- Total input chars/tokens cap (approx) enforced to prevent abuse
- `max_output_tokens` ≤ 2048 (configurable per tier later)

**ChatResponse (non-stream)**

```json
{
  "request_id": "uuid",
  "conversation_id": "string",
  "message": {
    "role": "assistant",
    "content": "string"
  },
  "usage": {
    "input_tokens": 123,
    "output_tokens": 456
  }
}
```

### 3.3 Streaming endpoint (SSE)

**Endpoint:** `POST /v1/chat/stream`

**Response**

- `Content-Type: text/event-stream`
- `Connection: keep-alive`
- `Cache-Control: no-cache, no-store`

**Event types**

| Event | Purpose |
|-------|---------|
| `event: meta` | First event: request_id, model, conversation_id |
| `event: token` | Incremental text |
| `event: done` | Final usage and message summary |
| `event: error` | Structured error payload (then close stream) |

**Example SSE format**

```
event: meta
data: {"request_id":"...","conversation_id":"...","model":"..."}

event: token
data: {"delta":"Hello"}

event: token
data: {"delta":" world"}

event: done
data: {"usage":{"input_tokens":...,"output_tokens":...}}
```

**Heartbeat:** Send `event: ping` every ~15 seconds to keep intermediaries happy.

---

## 4. Error Taxonomy (must be stable)

All errors return JSON:

```json
{
  "error": {
    "code": "string",
    "message": "string",
    "request_id": "uuid",
    "details": { "optional": "json" }
  }
}
```

### 4.1 HTTP status → error code map

| HTTP | Error code |
|------|------------|
| 400 | invalid_request |
| 401 | unauthorized |
| 403 | forbidden |
| 404 | not_found |
| 408 | timeout |
| 413 | payload_too_large |
| 429 | rate_limited (enforcement in M8, contract now) |
| 502 | provider_error |
| 503 | overloaded |
| 500 | internal_error |

### 4.2 SSE error event

When streaming, emit:

```
event: error
data: {"code":"provider_error","message":"...","request_id":"..."}
```

Then close stream.

---

## 5. Security (M6 scope)

### 5.1 JWT verification

- Validate signature (JWKS), issuer, audience, exp
- Extract: **user_id** = sub; **tenant_id** claim required; **roles**

### 5.2 Request hardening

- Body size limits (ALB/CloudFront later too)
- Strict schema validation
- Reject requests without tenant_id

### 5.3 Response hardening

- Never echo secrets
- Don’t include raw provider error bodies in response; sanitize

---

## 6. Runtime Safety & Backpressure (critical for “thousands concurrent”)

### 6.1 Timeouts

- **Provider call timeout** (e.g. 60–120s)
- **Stream idle timeout** (no tokens/heartbeats) → close gracefully
- **Per-request total time budget** (config)

### 6.2 Concurrency limits

- **MAX_CONCURRENT_STREAMS_PER_TASK** (e.g. 200–500 depending on CPU/mem)
- When exceeded: return **503 overloaded** with retry-after
- Track active streams via in-process counter (per-task, not global)

### 6.3 Connection pooling

- Single **httpx.AsyncClient** per process for provider requests: keep-alive, max connections tuned

### 6.4 Payload caps

- max messages
- max characters (approx token cap)
- max output tokens

---

## 7. Observability (M6 baseline; expands in M10)

### 7.1 Structured logs

Every request logs: **request_id**, **tenant_id**, **user_id_hash** (hash, not raw), **endpoint**, **latency_ms**, **outcome** (status code / error code). Never log message content by default.

### 7.2 Metrics (minimum)

- `http_requests_total{route,status}`
- `http_request_duration_ms{route}`
- `active_streams`
- `provider_latency_ms`
- `provider_errors_total{provider,code}`
- `overloaded_rejections_total`

### 7.3 Tracing

Trace spans: auth verify → validate request → provider call → streaming loop

---

## 8. Provider Abstraction (pluggable LLM)

### 8.1 Interface

**LLMProvider** must support:

- `generate(messages, settings)` → full response (non-stream)
- `stream(messages, settings)` → async iterator of deltas

### 8.2 Normalized provider response

- Unify: token deltas, final usage, finish reason
- Translate provider exceptions into **provider_error** or **timeout**

---

## 9. Implementation Notes (SSE in FastAPI)

### 9.1 SSE generator pattern

- Use **StreamingResponse** with async generator
- Yield properly formatted `event:` and `data:` lines
- Flush frequently

### 9.2 Client disconnect handling

- Catch **asyncio.CancelledError**
- Stop provider streaming
- Log “client_disconnected” outcome

### 9.3 Heartbeat

- Run a timer to emit **ping** if no tokens for 15 seconds

---

## 10. Local Development & Testing (M6)

### 10.1 Local provider stub

Implement a **fake provider** for deterministic tests:

- Returns “Hello” token by token
- Simulates latency
- Simulates provider errors

### 10.2 Tests

**Unit tests:** schema validation, auth parsing, error mapping, SSE event formatting

**Integration tests:** call `/v1/chat/stream` and verify event sequence; verify overload behavior when active streams exceed limit

---

## 11. Configuration (Typed Settings)

Example config keys (all validated at startup):

| Key | Purpose |
|-----|---------|
| APP_ENV | Environment |
| JWT_ISSUER, JWT_AUDIENCE, JWKS_URL | JWT validation |
| DEFAULT_MODEL | Default model name |
| MAX_MESSAGES | Max messages per request |
| MAX_INPUT_CHARS | Input cap |
| MAX_OUTPUT_TOKENS | Output cap |
| PROVIDER_TIMEOUT_SECS | Provider call timeout |
| MAX_CONCURRENT_STREAMS_PER_TASK | Backpressure limit |
| SSE_PING_SECS | Heartbeat interval |

---

## 12. Definition of Done (M6 acceptance checklist)

- [ ] POST `/v1/chat` returns a valid JSON response with request_id
- [ ] POST `/v1/chat/stream` streams SSE events (meta, token, done) reliably
- [ ] JWT auth required and validated; missing/invalid tokens → 401
- [ ] Tenant claim required; missing → 403
- [ ] Stable error taxonomy implemented for both JSON + SSE
- [ ] Concurrency guardrails: overload returns 503 (not random crashes)
- [ ] Structured logs include request_id and redact user content
- [ ] Unit + integration tests exist and run in CI
