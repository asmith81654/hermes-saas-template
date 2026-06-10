---
name: web-scraper
description: Scrape web pages, search the web, crawl websites, extract structured data, and map site URLs using the Web Scraper API or MCP server. Use when the user wants to fetch web page content, search online, crawl a site, extract data from URLs, discover page links, or configure an MCP web scraping tool. Also triggers on scrape, crawl, search, extract, map, web scraper, web scraping API, or MCP scraper setup.
---

# Web Scraper

A web scraping and search API with MCP support. Use this skill to help users fetch, search, crawl, and extract data from the web.

## Authentication

All requests require a Bearer token (prefix `efk-`):

```
Authorization: Bearer efk-YOUR_API_KEY
```

**Base URL:** `https://email-finder-mcp.johnwalk1192.workers.dev`

## REST API Endpoints

### Scrape — Fetch a single page

```
POST /v2/scrape
```

```bash
curl -X POST $BASE_URL/v2/scrape \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com", "formats": ["markdown"]}'
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string | Yes | URL to scrape |
| `formats` | string[] | No | `"markdown"`, `"html"`, `"links"`, `"screenshot"` |
| `onlyMainContent` | boolean | No | Extract only the main content |

Response shape: `{ "success": true, "data": { "markdown": "...", "metadata": {...} } }`

### Search — Search the web

```
POST /v2/search
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `query` | string | Yes | Search query |
| `limit` | number | No | Max results to return |

### Map — Discover all URLs on a site

```
POST /v2/map
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string | Yes | Site URL to map |

### Extract — Structured data extraction

```
POST /v2/extract
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `urls` | string[] | Yes | URLs to extract from |
| `prompt` | string | No | Natural language description of what to extract |
| `schema` | object | No | JSON Schema for expected output |

### Crawl — Crawl an entire website (async)

```
POST /v2/crawl
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `url` | string | Yes | Starting URL |
| `limit` | number | No | Max pages to crawl |
| `maxDiscoveryDepth` | number | No | Max link depth |

Returns a job `id`. Poll status with `GET /v2/crawl/{id}`.

**Related endpoints:**

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v2/crawl/{id}` | GET | Check job status and results |
| `/v2/crawl/{id}` | DELETE | Cancel the job |
| `/v2/crawl/{id}/errors` | GET | Get crawl errors |
| `/v2/crawl/active` | GET | List your active crawls |

### Batch Scrape — Scrape multiple URLs (async)

```
POST /v2/batch/scrape
```

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `urls` | string[] | Yes | List of URLs to scrape |

Returns a job `id`. Query with `GET /v2/batch/scrape/{id}`, cancel with `DELETE /v2/batch/scrape/{id}`.

## Async Job Polling Pattern

For `crawl` and `batch/scrape`, use this pattern:

```javascript
// 1. Start job
const { id } = await fetch(`${BASE_URL}/v2/crawl`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${API_KEY}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ url: 'https://example.com', limit: 50 }),
}).then(r => r.json());

// 2. Poll until done
let status, data;
while (true) {
  const res = await fetch(`${BASE_URL}/v2/crawl/${id}`, {
    headers: { Authorization: `Bearer ${API_KEY}` },
  }).then(r => r.json());

  status = res.data?.status;
  if (status === 'completed' || status === 'failed' || status === 'cancelled') {
    data = res;
    break;
  }
  await new Promise(r => setTimeout(r, 2000)); // wait 2s
}
```

## MCP Server Configuration

Connect AI assistants (Cursor, Claude Desktop, Windsurf, etc.) to use scraping tools directly.

### Cursor

Settings → MCP Servers → Add:

```json
{
  "mcpServers": {
    "web-scraper": {
      "type": "streamableHttp",
      "url": "https://email-finder-mcp.johnwalk1192.workers.dev/mcp",
      "headers": {
        "Authorization": "Bearer efk-YOUR_API_KEY"
      }
    }
  }
}
```

### Claude Desktop

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "web-scraper": {
      "type": "streamableHttp",
      "url": "https://email-finder-mcp.johnwalk1192.workers.dev/mcp",
      "headers": {
        "Authorization": "Bearer efk-YOUR_API_KEY"
      }
    }
  }
}
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `scrape` | Scrape a single URL for content |
| `crawl` | Start a website crawl job |
| `crawl_status` | Check crawl job status |
| `search` | Search the web and get page content |
| `map` | Discover all URLs on a site |
| `extract` | Extract structured data using natural language |

## Error Handling

| Code | Meaning | Action |
|------|---------|--------|
| 200 | Success | — |
| 401 | Invalid or missing API key | Check your `efk-` key |
| 403 | Account disabled | Contact admin |
| 404 | Job not found | Verify job ID belongs to you |
| 429 | Daily limit exceeded | Wait until next UTC day |

**429 response body:**

```json
{ "error": "Daily request limit exceeded", "limit": 100, "used": 100 }
```

## Rate Limits

- Each account has a daily request quota (set by admin).
- Every successful API call (including MCP tool calls) counts toward the quota.
- Quota resets at UTC 00:00 each day.

## Choosing the Right Endpoint

| Goal | Use |
|------|-----|
| Get content from one page | `POST /v2/scrape` |
| Search the web for a topic | `POST /v2/search` |
| Find all pages on a site | `POST /v2/map` |
| Extract structured data (pricing, specs, etc.) | `POST /v2/extract` |
| Scrape many pages in bulk | `POST /v2/batch/scrape` |
| Crawl an entire site deeply | `POST /v2/crawl` |

For detailed request/response examples, see [api-reference.md](api-reference.md).
