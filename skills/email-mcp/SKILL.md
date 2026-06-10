---
name: email-mcp
description: Automate email operations via MCP tools — send, read, list, reply, and check delivery status. Use when the user asks to send an email, check inbox, read emails, reply to messages, track email delivery, or perform any email-related task through the Resend MCP proxy.
---

# Email MCP — AI Agent Guide

Use MCP tools to send and receive emails through the Resend proxy. No API keys needed — your JWT identifies you.

## Available Tools

| Tool | Purpose | Key Params |
|------|---------|------------|
| `send_email` | Send email to recipients | `to[]`, `subject`, `text`/`html` |
| `list_inbox` | List received emails | `page`, `page_size`, `unread_only` |
| `read_email` | Read full email content (marks as read) | `email_id` |
| `get_email_status` | Check sent email delivery status | `email_id` |
| `reply_email` | Reply preserving thread | `email_id`, `text`/`html` |

## Tool Details

### send_email

Send an email from your assigned address.

```
to:       string[]  (required) — recipient addresses
subject:  string    (required) — subject line
text:     string    (optional) — plain-text body
html:     string    (optional) — HTML body
```

Returns: `{ id, status: "queued", from, to }`. Save the `id` for status checks.

**When to use**: User says "send an email", "email someone", "write and send a message".

### list_inbox

List emails in your inbox, newest first.

```
page:        number  (default: 1)
page_size:   number  (default: 20, max: 100)
unread_only: boolean (default: false)
```

Returns: `{ emails: [{ id, from_addr, subject, is_read, received_at }], total, page, page_size }`

**When to use**: "Check my inbox", "any new emails?", "show unread messages".

### read_email

Read full content of a specific email. Automatically marks as read.

```
email_id: string (required) — from list_inbox results
```

Returns: full email object including `body_text`, `body_html`, `from_addr`, `subject`, `message_id`.

**When to use**: "Read that email", "show me email abc123", "what does it say?".

### get_email_status

Check delivery status of a sent email.

```
email_id: string (required) — from send_email response
```

Returns: `{ id, status: "queued|sent|delivered|bounced|failed", last_event, ... }`

**When to use**: "Did my email get delivered?", "check if the email was sent".

### reply_email

Reply to a received email, preserving the conversation thread.

```
email_id: string (required) — ID of the email to reply to
text:     string (required) — reply body
html:     string (optional) — HTML reply
```

The `from` address and `In-Reply-To` header are set automatically based on the original email.

Returns: `{ id, status: "queued", reply_to_message_id, reply_to_addr }`

**When to use**: "Reply to that email", "respond to Sarah's message".

## Common Workflows

### Check and Read New Emails

1. `list_inbox` with `unread_only: true` → get list of unread emails
2. Pick an email → `read_email` with its `email_id`
3. Summarize content for the user

### Reply to an Email

1. `list_inbox` or `read_email` to find the target email
2. `reply_email` with `email_id` and crafted `text`
3. Confirm reply was queued (save returned `id`)

### Send and Verify Delivery

1. `send_email` with `to`, `subject`, `text`
2. Save returned `id`
3. Wait a few seconds → `get_email_status` with that `id`
4. Report status: delivered / bounced / failed

### Compose and Send

When user asks to send an email:
1. Ask for recipient, subject, and body (if not provided)
2. `send_email` with gathered params
3. Confirm success with email ID

## Important Notes

- **From address**: Automatically set to your assigned email alias — you cannot change it
- **Privacy**: You can only access your own inbox; other users' emails are isolated
- **Thread preservation**: Use `reply_email` (not `send_email`) to keep conversation threads intact
- **At least one of `text` or `html` is recommended** for `send_email` and `reply_email`
- **Pagination**: For large inboxes, use `page` and `page_size` to paginate results
- **Email IDs**: All IDs are UUIDs returned by `list_inbox` or `send_email` responses

## Error Handling

| Error | Cause | Fix |
|-------|-------|-----|
| `Email not found or access denied` | Wrong ID or not your email | Verify `email_id` from `list_inbox` |
| `'to' and 'subject' are required` | Missing required params | Provide `to` array and `subject` |
| `Original email not found` | Reply target doesn't exist | Use `list_inbox` to find valid email |

## Example Interaction

**User**: "Check if I have any unread emails and summarize them"

**Agent steps**:
1. Call `list_inbox` with `{"unread_only": true}`
2. For each result, call `read_email` with the email's `id`
3. Summarize each email (from, subject, key content)
4. Present summary to user
