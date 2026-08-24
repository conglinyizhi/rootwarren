# mbt-mdwiki REST API

Base URL: `http://127.0.0.1:8001`

The listener can be configured with `--ip` and `--port`, or with `MBT_MDWIKI_IP` and `PORT`. For example: `make run ARGS="--ip 127.0.0.1 --port 9000"`.

`PORT` can change the listener port. All endpoints below use `/api/v1` unless stated otherwise.

## Authentication

Two credential forms are supported.

**1. API key (Bearer):**

```sh
curl -H "Authorization: Bearer $MBT_MDWIKI_KEY" \
  http://127.0.0.1:8080/api/v1/docs
```

Keys have comma-separated scopes `read` or `read,write`. A key may optionally be bound to a user and a readable/writable slug prefix (e.g. `guide`), in which case the effective permission is the intersection of key scope, bound-user role, and configured prefixes. Documents outside the readable prefix return `403`; list results are filtered to the prefix.

**2. Cookie session (browser):**

Logging in via `POST /api/auth/login` sets an HttpOnly `mbt_auth` cookie. Browser `fetch` sends it automatically, so the frontend writes to protected endpoints without attaching a header.

Missing or invalid credentials return `401`. A valid credential without the needed scope returns `403`.

Create and revoke keys from the admin UI (frontend), or via the `/api/admin/*` endpoints. A newly created API key plaintext is shown once; only its SHA-256 hash is stored.

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

### Read a document

```http
GET /api/v1/docs/{slug}
Authorization: Bearer <key>
```

Requires `read` and the slug must be within the credential's readable prefix. Returns rendered Markdown HTML:

```json
{"slug":"guide/getting-started","html":"<h1>...</h1>"}
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
{"title":"mbt-mdwiki"}
```

## Auth Endpoints

```http
POST /api/auth/login        {username, password} -> {token, role} (sets mbt_auth cookie)
POST /api/auth/logout        revokes the session cookie
GET  /api/auth/me            -> {subject} if authenticated, else 401
```

## Admin Endpoints

All require an admin/superadmin session cookie.

```http
GET  /api/admin/users              list users
POST /api/admin/users              create user {username,password,role,write_prefix}
POST /api/admin/users/update       update user {id,role,write_prefix,enabled}
POST /api/admin/users/password     reset password {id,password}
GET  /api/admin/keys                list API keys
POST /api/admin/keys                create key {name,scopes,user_id,read_prefix,write_prefix}
POST /api/admin/keys/revoke         revoke key {id}
GET  /api/admin/site                read site config
POST /api/admin/site                save site config {title,public,show_tree,llms_mode,llms_prefixes}
```

Roles: `superadmin` can manage any account; `admin` cannot create/edit/reset a `superadmin`. `site.public=false` blocks anonymous reads of `/d/` and `/`.

## Document Metadata (Typecho-style)

Documents use Markdown front matter (a `---\n...\n---` block at the top) with Typecho-like fields:

```yaml
---
title: 分类文章
tags: guide, moonbit
status: public      # public | private | hidden | draft
category: guide     # classification slug
---
# 正文...
```

`GET /api/v1/docs/{slug}` returns `slug`, rendered `html`, `content` (raw Markdown), `category`, and `status`.

## Categories

```http
GET /api/v1/categories          list categories with document counts
GET /category/{slug}            SSR category page (lists its documents)
GET /posts/{slug}               SSR permalink alias (same content as /d/{slug})
```

## Doc Links & Backlinks

Wiki-internal Markdown links (relative paths, e.g. `guide/getting-started`) are rewritten to absolute `/{slug}` form when rendered, resolving relative to the current document's directory. A link to a document stores a reverse mapping in `meta/links.json` (`target -> [source, ...]`), refreshed when a document is saved or deleted.

```text
GET /api/v1/backlinks/{slug}     # documents that link to {slug}
```

Returns `{ "slug": ..., "backlinks": ["source_slug", ...] }`. Requires `read` scope. SSR reading pages also render a "链入页面" (backlinks) section.

## RSS / Atom

```http
GET /feed
```

Returns an RSS 2.0 feed (`application/rss+xml`) walking all public documents' titles, links, and tags.

## llms.txt

```http
GET /llms.txt
```

The server generates a Markdown index from document front matter titles, tags, and slugs. It supports three admin-configured modes: `public` (default, all documents), `partial` (only comma-separated safe slug prefixes, shown only when that mode is selected), and `disabled` (returns `404`). The admin UI links to the official spec at https://llmstxt.org/. The generated links point to rendered `/d/{slug}` pages. The output follows the intent of [The /llms.txt file, v2](https://llmstxt.org/) and [AnswerDotAI/llms-txt](https://github.com/answerdotai/llms-txt).

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

The admin overview shows up to ten users in a table and links to `/admin/users` for the full editable user table. The admin page uses a sidebar for site settings, users and permissions, and API keys. User records are stored in `meta/users.json` with password hashes only. Roles are ordered `superadmin` > `admin` > `write` > `read` > `none`; a `write` user may be restricted to a document path prefix such as `guide`, including only `guide/...` descendants. A `superadmin` can manage any account and assign any role; an `admin` can manage non-superuser accounts and may not create, edit, enable/disable, or reset the password of a `superadmin`. The built-in operator credential is treated as a `superadmin`. Usernames and write prefixes are validated, and document slugs reject absolute paths, empty segments, `.`/`..`, and non-safe characters to prevent traversal. API keys can optionally bind to an enabled user and apply independent readable/writable slug prefixes; the effective permission is the intersection of key scope, bound-user role, and configured prefixes. The site product name is configured as `site.title` from the admin page and is used in rendered page titles as `{document title} - {product name}`. The home page also renders front matter tags as visible tag chips. The home page follows the same rule. In public mode it renders `content/index.md`; in private mode it requires a session. The page reads the same Markdown source as the API and renders HTML through CommonMark. Raw HTML from Markdown is rendered in safe mode. Relative Markdown links are intended to point to other Wiki pages.

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
