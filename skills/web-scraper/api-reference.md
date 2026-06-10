# API Reference

Detailed request/response examples for all Web Scraper endpoints.

**Base URL:** `https://email-finder-mcp.johnwalk1192.workers.dev`

---

## Scrape

### Request

```bash
curl -X POST $BASE_URL/v2/scrape \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com",
    "formats": ["markdown", "links"],
    "onlyMainContent": true
  }'
```

### Response (200)

```json
{
  "success": true,
  "data": {
    "markdown": "# Example Domain\n\nThis domain is for use in documentation examples...",
    "links": ["https://iana.org/domains/example"],
    "metadata": {
      "title": "Example Domain",
      "language": "en",
      "sourceURL": "https://example.com",
      "url": "https://example.com/",
      "statusCode": 200,
      "contentType": "text/html"
    }
  }
}
```

---

## Search

### Request

```bash
curl -X POST $BASE_URL/v2/search \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "cloudflare workers edge computing", "limit": 5}'
```

### Response (200)

```json
{
  "success": true,
  "data": [
    {
      "url": "https://developers.cloudflare.com/workers/",
      "title": "Cloudflare Workers",
      "markdown": "# Cloudflare Workers\n\n...",
      "metadata": { "title": "...", "sourceURL": "..." }
    }
  ]
}
```

---

## Map

### Request

```bash
curl -X POST $BASE_URL/v2/map \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com"}'
```

### Response (200)

```json
{
  "success": true,
  "links": [
    "https://example.com/",
    "https://example.com/about",
    "https://example.com/contact",
    "https://example.com/blog/post-1"
  ]
}
```

---

## Extract

### Request

```bash
curl -X POST $BASE_URL/v2/extract \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "urls": ["https://example.com/pricing"],
    "prompt": "Extract pricing plans with name, monthly price, and features list"
  }'
```

### With JSON Schema

```bash
curl -X POST $BASE_URL/v2/extract \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "urls": ["https://example.com/pricing"],
    "prompt": "Extract all pricing plans",
    "schema": {
      "type": "object",
      "properties": {
        "plans": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "name": { "type": "string" },
              "price": { "type": "number" },
              "features": { "type": "array", "items": { "type": "string" } }
            }
          }
        }
      }
    }
  }'
```

### Response (200)

```json
{
  "success": true,
  "data": {
    "plans": [
      { "name": "Starter", "price": 9, "features": ["5 projects", "1 user"] },
      { "name": "Pro", "price": 29, "features": ["50 projects", "10 users"] }
    ]
  }
}
```

---

## Crawl (Async)

### Start Crawl

```bash
curl -X POST $BASE_URL/v2/crawl \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com",
    "limit": 50,
    "maxDiscoveryDepth": 2
  }'
```

**Response (200):**

```json
{
  "success": true,
  "id": "abc123-def456-...",
  "url": "https://example.com",
  "status": "scraping"
}
```

### Check Status

```bash
curl $BASE_URL/v2/crawl/abc123-def456-... \
  -H "Authorization: Bearer $API_KEY"
```

**Response — In Progress:**

```json
{
  "success": true,
  "status": "scraping",
  "total": 50,
  "completed": 12,
  "creditsUsed": 12
}
```

**Response — Completed:**

```json
{
  "success": true,
  "status": "completed",
  "total": 45,
  "completed": 45,
  "creditsUsed": 45,
  "data": [
    {
      "markdown": "# Page Title\n...",
      "metadata": { "sourceURL": "https://example.com/page1", "..." : "..." }
    }
  ]
}
```

### Cancel Crawl

```bash
curl -X DELETE $BASE_URL/v2/crawl/abc123-def456-... \
  -H "Authorization: Bearer $API_KEY"
```

### Get Crawl Errors

```bash
curl $BASE_URL/v2/crawl/abc123-def456-.../errors \
  -H "Authorization: Bearer $API_KEY"
```

### List Active Crawls

```bash
curl $BASE_URL/v2/crawl/active \
  -H "Authorization: Bearer $API_KEY"
```

Only returns your own active jobs.

---

## Batch Scrape (Async)

### Start Batch

```bash
curl -X POST $BASE_URL/v2/batch/scrape \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "urls": [
      "https://example.com/page1",
      "https://example.com/page2",
      "https://example.com/page3"
    ]
  }'
```

**Response (200):**

```json
{
  "success": true,
  "id": "batch-abc123-...",
  "status": "scraping"
}
```

### Check Status / Cancel

Same pattern as Crawl:

- `GET /v2/batch/scrape/{id}` — status and results
- `DELETE /v2/batch/scrape/{id}` — cancel

---

## Error Responses

### 401 Unauthorized

```json
{ "error": "Missing or invalid Authorization header" }
```

or

```json
{ "error": "Invalid API key" }
```

### 403 Forbidden

```json
{ "error": "Account disabled" }
```

### 404 Not Found

```json
{ "error": "Job not found" }
```

Returned when a job ID doesn't belong to you or doesn't exist.

### 429 Too Many Requests

```json
{
  "error": "Daily request limit exceeded",
  "limit": 100,
  "used": 100
}
```

Quota resets at UTC 00:00.

---

## JavaScript Usage Example

```javascript
const BASE_URL = 'https://email-finder-mcp.johnwalk1192.workers.dev';
const API_KEY = 'efk-your-key';

const headers = {
  Authorization: `Bearer ${API_KEY}`,
  'Content-Type': 'application/json',
};

// Scrape a page
async function scrape(url) {
  const res = await fetch(`${BASE_URL}/v2/scrape`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ url, formats: ['markdown'] }),
  });
  if (res.status === 429) {
    const { limit } = await res.json();
    throw new Error(`Daily limit reached (${limit}). Resets at UTC midnight.`);
  }
  const { data } = await res.json();
  return data.markdown;
}

// Search the web
async function search(query, limit = 5) {
  const res = await fetch(`${BASE_URL}/v2/search`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ query, limit }),
  });
  const { data } = await res.json();
  return data;
}
```
