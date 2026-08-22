# mbt-mdwiki REST API

Base URL: `http://127.0.0.1:8001`

`PORT` can change the listener port. All endpoints below use `/api/v1` unless stated otherwise.

## Authentication

Protected requests require an API key:

```sh
curl -H "Authorization: Bearer $MBT_MDWIKI_KEY" \
  http://127.0.0.1:8001/api/v1/docs
```

Keys have comma-separated scopes:

- `read`: list, read, search, and read config.
- `read,write`: all `read` operations plus document creation, overwrite, and deletion.

Missing or invalid credentials return `401`. A valid key without the needed scope returns `403`.

Create and revoke keys from `/admin/login`. The server requires `ADMIN_TOKEN` to be set at startup. A newly created key is shown once; record it in the calling client's secret store, never in a document or repository.

## Document Slugs

A slug is the relative location under `content/`, without `.md`.

Examples:

- `index` maps to `content/index.md`
- `guide/getting-started` maps to `content/guide/getting-started.md`

Only letters, numbers, `-`, `_`, and `/` are accepted. Empty segments, `.` and `..` are rejected.

## Endpoints

### Health check

```http
GET /health
```

Public. Returns plain text `ok`.

### List documents

```http
GET /api/v1/docs
Authorization: Bearer <key>
```

Requires `read`.

```json
{"docs":["index","guide/getting-started"]}
```

### Read raw Markdown

```http
GET /api/v1/docs/{slug}
Authorization: Bearer <key>
```

Requires `read`. Returns `text/markdown`.

```sh
curl -H "Authorization: Bearer $MBT_MDWIKI_KEY" \
  http://127.0.0.1:8001/api/v1/docs/index
```

### Create or overwrite a document

```http
PUT /api/v1/docs/{slug}
Authorization: Bearer <key>
Content-Type: text/markdown

<Markdown body>
```

Requires `write`.

```sh
curl -X PUT \
  -H "Authorization: Bearer $MBT_MDWIKI_KEY" \
  -H "Content-Type: text/markdown" \
  --data-binary $'# New document\n\nWritten by an API client.\n' \
  http://127.0.0.1:8001/api/v1/docs/notes/new-document
```

Success:

```json
{"ok":true}
```

### Delete a document

```http
DELETE /api/v1/docs/{slug}
Authorization: Bearer <key>
```

Requires `write`. Deleting an absent document is treated as success.

```sh
curl -X DELETE \
  -H "Authorization: Bearer $MBT_MDWIKI_KEY" \
  http://127.0.0.1:8001/api/v1/docs/notes/new-document
```

### Keyword search

```http
GET /api/v1/search?q={query}
Authorization: Bearer <key>
```

Requires `read`. The MVP performs case-sensitive substring matching against each slug and Markdown source. The current server does not percent-decode query values, so use plain ASCII query text without `&` or `=` until URL decoding is implemented.

```sh
curl -G \
  -H "Authorization: Bearer $MBT_MDWIKI_KEY" \
  --data-urlencode 'q=keyword' \
  http://127.0.0.1:8001/api/v1/search
```

```json
{"results":["notes/new-document"]}
```

### Read site configuration

```http
GET /api/v1/config
Authorization: Bearer <key>
```

Requires `read`.

```json
{"site":{"title":"mbt-mdwiki","description":""}}
```

## Client Web App

```http
GET /
GET /frontend.js
```

`make run` builds and serves the MoonBit JS client from the same native server. The client keeps the API key in memory, lists documents, searches, reads Markdown, and exposes write controls only when the key has `read,write` scope. It does not add OAuth, MCP, vector search, offline sync, or collaboration.

The client implementation brief is in [`docs/CLIENT.md`](CLIENT.md).

### Startup Bootstrap URL

Each server start generates one random bootstrap URL printed only in the console:

```text
http://127.0.0.1:8001/?api_key=mk_...
```

The first request to that URL exchanges the key for an HttpOnly `mbt_session` cookie and returns `302 Location: /`. The bootstrap key is held only in process memory, is invalid after one exchange, and is not stored in `meta/api_keys.json`. The session expires when the server process stops. A normal API key still uses `Authorization: Bearer <key>`.

## Public Browser View

```http
GET /d/{slug}
```

Public. Reads the same Markdown source as the API and renders HTML through CommonMark. Raw HTML from Markdown is rendered in safe mode.

```sh
xdg-open http://127.0.0.1:8001/d/index
```

## Error Responses

Errors use JSON for API routes:

```json
{"error":{"code":"401","message":"invalid or missing API key"}}
```

Common status codes:

- `400`: malformed request or invalid slug
- `401`: missing or invalid API key
- `403`: key lacks required scope
- `404`: endpoint or document does not exist

## Client Integration Pattern

An agent should:

1. Obtain a `read,write` key from its operator and store it as a secret, for example `MBT_MDWIKI_KEY`.
2. List documents before choosing a slug.
3. Read a document before overwriting it when preserving user content matters.
4. Use `PUT` with full Markdown content; there is no partial-update endpoint in this MVP.
5. Use `/search` for keyword retrieval. Text-file vector indexes belong to a later phase and are not available yet.
