# mbt-mdwiki REST API

Base URL: `http://127.0.0.1:8001`

The listener can be configured with `--ip` and `--port`, or with `MBT_MDWIKI_IP` and `PORT`. For example: `make run ARGS="--ip 127.0.0.1 --port 9000"`.

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

Create and revoke keys from `/admin/login`. The server can use `ADMIN_TOKEN` for fixed-token form login, but it is optional. When unset, use the one-time random admin URL printed at startup. A newly created API key is shown once; record it in the calling client's secret store, never in a document or repository.

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

## llms.txt

```http
GET /llms.txt
```

The server generates a Markdown index from document front matter titles, tags, and slugs. It supports three admin-configured modes: `public` (default, all documents), `partial` (only comma-separated safe slug prefixes), and `disabled` (returns `404`). The generated links point to rendered `/d/{slug}` pages. The output follows the intent of [The /llms.txt file, v2](https://llmstxt.org/) and [AnswerDotAI/llms-txt](https://github.com/answerdotai/llms-txt).

## Client Web App

```http
GET /
GET /frontend.js
```

`make run` builds and serves the MoonBit JS client from the same native server. The client keeps the API key in memory, lists documents, searches, reads Markdown, and exposes write controls only when the key has `read,write` scope. It does not add OAuth, MCP, vector search, offline sync, or collaboration.

The client implementation brief is in [`docs/CLIENT.md`](CLIENT.md).

### Startup Admin URL

Each server start generates one random, one-time admin URL printed only in the console. Opening it exchanges the key for an HttpOnly `mbt_auth` JWT Cookie and redirects to the admin page. The key does not create a persistent API key. The JWT uses an in-memory process secret and remains valid until logout or server shutdown. When `ADMIN_TOKEN` is configured, it provides the initial administrator password for `/login`. After entering the backend, set a persistent Admin Key in the “管理员登录” section; only its SHA-256 hash is stored in `meta/config.json`. After that, `/login` accepts the configured administrator username and the persisted Admin Key; the default username is `operator`, not `admin`. When no Admin Key is configured yet, use the one-time admin URL printed by the console to enter the backend and set one. Browser users no longer need a client bootstrap key. Normal API clients still use `Authorization: Bearer <api_key>`.

## Public Browser View

```http
GET /d/{slug}
```

The admin setting `site.public` controls anonymous reading:

- `true` or unset: anonymous users can read rendered Markdown.
- `false`: anonymous users receive `403`; an admin or client session can still read.

The admin overview shows up to ten users in a table and links to `/admin/users` for the full editable user table. The admin page uses a sidebar for site settings, users and permissions, and API keys. User records are stored in `meta/users.json` with password hashes only. Roles are `admin`, `read`, `write`, and `none`; a `write` user may be restricted to a document path prefix such as `guide`, including only `guide/...` descendants. Usernames and write prefixes are validated, and document slugs reject absolute paths, empty segments, `.`/`..`, and non-safe characters to prevent traversal. API keys can optionally bind to an enabled user and apply independent readable/writable slug prefixes; the effective permission is the intersection of key scope, bound-user role, and configured prefixes. The site product name is configured as `site.title` from the admin page and is used in rendered page titles as `{document title} - {product name}`. The home page also renders front matter tags as visible tag chips. The home page follows the same rule. In public mode it renders `content/index.md`; in private mode it requires a session. The page reads the same Markdown source as the API and renders HTML through CommonMark. Raw HTML from Markdown is rendered in safe mode. Relative Markdown links are intended to point to other Wiki pages.

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
