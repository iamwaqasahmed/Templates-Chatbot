# M7 — Conversation Storage v1 (DynamoDB Durable State + Idempotency + Ordering) — Technical Design v1

M7 makes chat correct under scale: conversations and messages are stored durably, requests are idempotent, message ordering is enforced, and the API becomes safe under retries, timeouts, client reconnects, and multi-instance scaling.

This milestone plugs into M6 API without breaking contracts; it adds persistence guarantees.

---

## 1. Goals, Non-Goals, Outcomes

### Goals

- **Durable storage** for: conversations (metadata), messages (user + assistant), request idempotency + dedupe
- **Enforce:** per-conversation message ordering; consistent regeneration/retries (no duplicates)
- **Define:** retention + TTL policies; access patterns + indexes
- **Implement:** persistence hooks in FastAPI orchestrator; basic “list/get conversation” endpoints

### Non-goals (later milestones)

- Redis caching (M8)
- Vector store / RAG (M14)
- Tool invocation trace persistence (M13)
- Billing-grade metering (M15/M18)
- Multi-region active-active (M17+)

### Outcomes

- DynamoDB tables created via Terraform data module/stack
- API writes: user message immediately; assistant message at end
- **Idempotency:** same idempotency key → same response, no duplicates
- Message ordering guaranteed per conversation

---

## 2. Data Model Strategy (DynamoDB)

### Key design principles

- **Tenant isolation:** Every partition key includes tenant_id or conversation key that is tenant-scoped.
- **Hot partition avoidance:** Use conversation_id as PK for messages (high cardinality).
- **Minimal GSIs:** Only add what you need for your access patterns.

### Core access patterns (must support)

- Create conversation
- List conversations by tenant+user (sorted by recent)
- Get conversation metadata
- Append message (user/assistant), ordered
- List messages in a conversation (paged, ordered)
- **Idempotent request processing:** “replay safe” for /chat and /chat/stream

---

## 3. Table Design (recommended v1)

### Table A: chat_conversations

Stores conversation metadata and supports listing by user.

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}#USER#{user_id}` |
| **SK** | `CONV#{conversation_id}` |
| **Attributes** | conversation_id, tenant_id, user_id, title (optional), created_at, updated_at (update on each new message), model, status (active\|archived\|deleted), last_message_preview, ttl (optional) |

**GSI for “recent conversations” (optional, recommended for v1)**

- **GSI1PK** = `TENANT#{tenant_id}#USER#{user_id}`
- **GSI1SK** = `UPDATED#{updated_at}#CONV#{conversation_id}`
- Query GSI1 in descending order to get recent.

---

### Table B: chat_messages

Stores messages for a conversation.

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}#CONV#{conversation_id}` |
| **SK** | `TS#{timestamp_ms}#MSG#{message_id}` or (Option A) `SEQ#{seq_padded}#MSG#{message_id}` |
| **Attributes** | message_id, tenant_id, conversation_id, role (user\|assistant\|system\|tool), content, created_at, seq (optional), provider, usage_input_tokens, usage_output_tokens, finish_reason, metadata, ttl |

**Pagination:** Query by PK, limit N, with ExclusiveStartKey.

---

### Table C: chat_requests (Idempotency + request tracking)

Ensures retries do not duplicate processing.

| Item | Design |
|------|--------|
| **PK** | `TENANT#{tenant_id}#REQ#{idempotency_key}` |
| **SK** | `REQ` (fixed) |
| **Attributes** | request_id, tenant_id, user_id, conversation_id, status (in_progress\|completed\|failed), created_at, updated_at, response_message_id (when completed), response_preview (optional), error_code/error_message (if failed), ttl |

**Uniqueness rule:** For a given tenant, the idempotency key is unique. Use conditional write on creation to enforce single owner.

---

## 4. Ordering & Concurrency (the tricky part)

### Why this matters

Multiple client retries, parallel calls, or multiple devices can attempt to write messages simultaneously. We must avoid: two “assistant” responses for the same user message; out-of-order message history.

### Recommended v1 approach (safe and simple)

- Use **idempotency per chat request** (per “user send message” action).
- Optionally: only one in-progress request per conversation per user (can be relaxed later).
- Use **DynamoDB conditional writes** + an atomic counter.

### Option A (best practice): per-conversation sequence counter item

- **Counter item** in chat_messages table:
  - PK = `TENANT#{tenant_id}#CONV#{conversation_id}`
  - SK = `COUNTER`
  - Attribute: `next_seq` (number)
- When writing a message: **UpdateItem** on COUNTER with `ADD next_seq :inc` and return new value; use returned seq to form message SK: `SK = SEQ#{seq_padded}#MSG#{message_id}`.
- **Pros:** Deterministic ordering, avoids timestamp collisions. **Cons:** Extra write per message (acceptable).

### Option B (timestamp-only SK)

- Use timestamp_ms and message_id in SK. **Pros:** Fewer writes. **Cons:** Ordering “mostly correct” but can get messy with same-ms and cross-device; enterprise-grade prefers Option A.

**Recommendation:** Use **Option A** for “best-of-the-best”.

---

## 5. Idempotency Protocol (end-to-end)

### Client responsibility (frontend)

- Generate **Idempotency-Key** per user send action (UUID).
- Include header on chat endpoints: `Idempotency-Key: <uuid>`.
- For stream reconnect attempts, reuse same key.

### Server behavior

| Step | Action |
|------|--------|
| 1 | On POST /v1/chat or /v1/chat/stream: try **PutItem** into chat_requests with condition `attribute_not_exists(PK)` |
| 2 | If succeeds → you own the request (process it). If fails → request exists: if status=completed → return stored result pointer; if status=in_progress → return 409/202 “in progress”; if status=failed → allow retry per policy |
| 3 | Write user message (durable): use sequence counter to allocate seq; Put message item |
| 4 | Generate assistant response; stream tokens to client (SSE) |
| 5 | On completion: allocate seq, write assistant message item |
| 6 | Mark request completed: update chat_requests with status=completed + response_message_id |
| 7 | On failure: update chat_requests status=failed + error_code/message |

### SSE nuance

If a client disconnects mid-stream: the request may still complete server-side. On reconnect with same idempotency key: server sees status=completed and can re-stream from stored assistant message (v1: return full message; advanced: stream from saved chunks later).

---

## 6. API Endpoints Added/Updated in M7

### Updated chat endpoints

- **POST /v1/chat:** creates conversation if missing; persists messages; respects Idempotency-Key.
- **POST /v1/chat/stream:** same, but streams output; if already completed, returns stored final answer (stream as single token chunk or JSON fallback).

### New endpoints (minimal set)

| Method | Path | Purpose |
|--------|------|---------|
| POST | /v1/conversations | Create new conversation (optional; can be implicit on first message); returns conversation_id |
| GET | /v1/conversations?limit=20&cursor=... | List conversations for current user (tenant-scoped); uses GSI1 order by updated_at |
| GET | /v1/conversations/{conversation_id} | Get metadata (validate tenant/user ownership) |
| GET | /v1/conversations/{conversation_id}/messages?limit=50&cursor=... | List messages ordered by seq |
| POST | /v1/conversations/{conversation_id}/archive | Set status archived (optional in v1) |

---

## 7. Retention, TTL, and Data Lifecycle

| Table | TTL / retention |
|-------|----------------|
| **Conversations** | Optional; retention by tenant settings later; can set ttl and cascade-delete messages via background job (M12/M15) |
| **Messages** | Optional TTL; recommended default: no TTL early; implement explicit deletion later |
| **Requests** | **Yes:** TTL strongly recommended; default 48 hours to cover retries/reconnects |

---

## 8. Terraform: Data Stack (DynamoDB + KMS)

### New module: `modules/data-dynamodb-chat`

Creates:

- chat_conversations table
- chat_messages table
- chat_requests table
- KMS key (or use shared key from foundation) for table encryption
- **PITR** enabled
- **Capacity mode:** PAY_PER_REQUEST (recommended for unpredictable load)
- **SSE** enabled with KMS
- **TTL** enabled on chat_requests.ttl (and messages if chosen)

### Live stack

```
infra/terraform/live/{dev,staging,prod}/data/
  dynamodb_chat.tf
  outputs.tf
```

**Outputs** consumed by API: table names/ARNs, KMS key ARN.

---

## 9. IAM Changes (Task role permissions)

Update **chat-api task role** (defined in M4 module) to include:

- **DynamoDB:** dynamodb:PutItem, GetItem, UpdateItem, Query, ConditionCheckItem (optional); only on specific table ARNs.
- **KMS** (if CMK): kms:Decrypt, kms:Encrypt, kms:GenerateDataKey with kms:ViaService condition for DynamoDB.

---

## 10. Implementation Details in API (FastAPI)

### 10.1 Persistence flow in orchestrator (recommended)

1. `ensure_conversation_exists()`
2. `begin_idempotent_request()`
3. `append_user_message()`
4. `stream_assistant()` (M6 provider streaming)
5. `append_assistant_message()`
6. `complete_request()`

### 10.2 DynamoDB client settings

- Use boto3/botocore with retries enabled and timeouts set.
- One client per process.

### 10.3 Conditional writes (important)

- **chat_requests creation:** condition `attribute_not_exists(PK)`.
- **Counter update:** if counter item missing, create with conditional put then update (or use UpdateItem with if_not_exists).

### 10.4 Cursor encoding

Return cursors as opaque **base64 JSON** of DynamoDB LastEvaluatedKey.

---

## 11. Testing Plan (must-have)

### Unit tests

- Idempotency: same key returns same result pointer.
- Ordering: seq increments and message retrieval order is correct.
- Unauthorized tenant: access forbidden.

### Integration tests (local dynamodb-local)

- Create conversation → send chat → list messages → verify stored messages.
- Retry POST /chat with same idempotency key → no duplicate assistant message.
- Simulated disconnect: start stream, cancel client, then call again with same idempotency key → returns completed stored response.

---

## 12. Operational Considerations

| Topic | Notes |
|-------|------|
| **Hot partitions** | chat_messages PK per conversation → good distribution; chat_conversations PK per user → can be hot for power users; acceptable early; can shard later |
| **Capacity mode** | On-demand (PAY_PER_REQUEST) early; later (M18) evaluate provisioned + autoscaling if cost demands |
| **Consistency** | Reads eventually consistent by default; use consistent reads for request lookup only if needed |

---

## 13. Definition of Done (M7 acceptance checklist)

- [ ] DynamoDB tables created via Terraform (encrypted, PITR enabled)
- [ ] POST /v1/chat persists user and assistant messages
- [ ] POST /v1/chat/stream persists final assistant message on completion
- [ ] Idempotency implemented using Idempotency-Key and chat_requests
- [ ] Message ordering is deterministic (sequence counter approach)
- [ ] New endpoints: list conversations, get messages (paged)
- [ ] Tests cover idempotency and ordering with dynamodb-local
- [ ] No PII logged; message content not logged in production mode
