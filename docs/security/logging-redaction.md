# Logging & PII Redaction Policy

## Principles

1. **Never log raw user message content** in production by default.
2. **Always use structured JSON logs** for machine-parseable output.
3. **Correlation IDs** (`request_id`, `conversation_id`, `tenant_id`) must
   appear in every log line within a request scope.
4. **User identifiers** should be hashed (`user_id_hash`) — never raw
   email or personal data.

## Log Fields (Standard)

| Field              | Example                      | Required | Notes               |
|--------------------|------------------------------|----------|----------------------|
| `timestamp`        | `2026-02-07T12:00:00.000Z`  | Yes      | ISO 8601             |
| `level`            | `INFO`                       | Yes      |                      |
| `service`          | `chat-api`                   | Yes      |                      |
| `event`            | `chat_request_received`      | Yes      | Machine-readable     |
| `request_id`       | `uuid`                       | Yes      |                      |
| `tenant_id`        | `tenant_abc`                 | Yes      |                      |
| `user_id_hash`     | `sha256_prefix`              | Yes      | Never raw user ID    |
| `conversation_id`  | `conv_xxx`                   | If applicable |                 |
| `latency_ms`       | `142`                        | If applicable |                 |

## What NOT to Log

- Raw chat messages (user or assistant content)
- Full JWT tokens
- API keys
- Email addresses, phone numbers, names
- IP addresses (except in WAF/access logs with short retention)

## Debug Mode (Opt-in)

- Tenant admins may opt in to "debug traces" that include message content.
- Debug traces have a **short retention** (e.g., 24–72 hours).
- Debug mode is flagged in the log entry: `"debug_trace": true`.

## Implementation

Logging is configured in `services/chat-api/src/app/core/logging.py` using
**structlog** with:

- `structlog.contextvars` for request-scoped fields
- JSON renderer in non-local environments
- Console renderer for local development
