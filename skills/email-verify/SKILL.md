---
name: email-verify
description: Verify whether email addresses exist and are deliverable without sending any email. Use when the user wants to check, validate, verify, or clean email addresses, assess email deliverability, or validate an email list. Triggers on phrases like "verify this email", "check if email exists", "validate email", "email deliverability", "is this email real", "clean email list".
---

# Email Verification Skill

Verify whether an email address exists and is deliverable — without sending any email. Use this skill whenever the user asks to verify, validate, or check email addresses, clean an email list, or assess email deliverability.

## Prerequisites

Before making any API calls, ask the user for their **API key**. If they don't have one, tell them to contact their service administrator.

Store the key as `$API_KEY` once provided. Do NOT hardcode any key — always obtain it from the user.

## Endpoint

```
POST https://revotria-email-verify.johnwalk1192.workers.dev/v0/check_email
```

Authenticate via either header:
- `Authorization: Bearer <API_KEY>`
- `X-API-Key: <API_KEY>`

## Making a Request

Send a JSON body with the `to_email` field:

```json
{"to_email": "test@example.com"}
```

You can make the call with `curl` via `bash`, or with `web_fetch` using a POST. Example:

```bash
curl -s -X POST "https://revotria-email-verify.johnwalk1192.workers.dev/v0/check_email" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"to_email":"test@example.com"}'
```

For **batch verification**, use the batch endpoint to verify up to 100 emails in a single call (each email still counts as 1 toward the daily quota):

```bash
curl -s -X POST "https://revotria-email-verify.johnwalk1192.workers.dev/v0/check_email/batch" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"to_emails":["test@example.com","hello@stripe.com","admin@proton.me"]}'
```

The response wraps results in a `results` array with a `summary` object:
```json
{
  "results": [ ... ],
  "summary": {
    "total": 3,
    "processed": 3,
    "remaining_quota": 997,
    "truncated": false
  }
}
```

If the remaining daily quota is less than the requested batch size, only the available amount is processed and `truncated` is `true`. If quota is already 0, the endpoint returns HTTP 429 immediately.

## Interpreting the Response

The response is JSON. The most important field is `is_reachable`:

| Value | Meaning | Action |
|---|---|---|
| `safe` | Address exists and is deliverable | ✅ Safe to send |
| `risky` | Domain accepts mail but can't confirm the specific address (e.g. catch-all domain). Mail is usually delivered successfully. | ⚠️ Proceed with caution |
| `invalid` | Address does not exist, is disabled, or domain has no mail server | ❌ Do not send — will bounce |
| `unknown` | Could not determine (SMTP connection failed). Try again later or treat as risky. | ❓ Inconclusive |

Additional useful fields:

| Field | Description |
|---|---|
| `smtp.is_deliverable` | Whether the SMTP server accepted the address |
| `smtp.is_catch_all` | Whether the domain accepts all addresses (catch-all) |
| `smtp.is_disabled` | Whether the mailbox is disabled |
| `smtp.has_full_inbox` | Whether the inbox is full |
| `misc.is_disposable` | Whether it's a disposable/throwaway email |
| `misc.is_role_account` | Whether it's a role account (admin@, support@, etc.) |
| `syntax.is_valid_syntax` | Whether the email format is valid |
| `mx.accepts_mail` | Whether the domain has MX records |
| `suggestion` | Syntax correction suggestion (if the email has a typo) |

A full response example:

```json
{
  "input": "someone@gmail.com",
  "is_reachable": "invalid",
  "misc": { "is_disposable": false, "is_role_account": false },
  "mx": { "accepts_mail": true, "records": ["gmail-smtp-in.l.google.com."] },
  "smtp": { "can_connect_smtp": true, "is_deliverable": false, "is_disabled": true, "is_catch_all": false, "has_full_inbox": false },
  "syntax": { "domain": "gmail.com", "is_valid_syntax": true, "username": "someone", "suggestion": null }
}
```

## Error Handling

| HTTP Status | Error Body | What to Do |
|---|---|---|
| 200 | — | Success — read `is_reachable` |
| 400 | `{"error":"missing required field: to_email"}` | Check your request body |
| 401 | `{"error":"invalid API key"}` | Ask the user to double-check their key |
| 429 | `{"error":"daily quota exceeded","daily_quota":N,"used":N}` | Wait until next UTC day, or tell the user their quota is exhausted |
| 502 | `{"error":"upstream backend unreachable"}` | Retry in 1-2 minutes |

## Presenting Results to the User

When showing verification results, always:
1. Group by `is_reachable` (safe / risky / invalid / unknown)
2. Highlight any `invalid` addresses — these will bounce
3. Note that `risky` addresses with `is_catch_all: true` are likely still deliverable
4. Summarize with counts: "X safe, Y risky, Z invalid, W unknown out of N total"
