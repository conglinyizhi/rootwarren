# rootwarren Client Design Brief

Use this document when designing a client for `rootwarren`. The client may be a Web UI, TUI, desktop app, or an agent-managed integration. Do not assume a particular frontend framework.

The product is a **document backend for people and language-model clients**. Markdown in the server's `content/` directory remains the source of truth. A client is a view and control surface over that content; it must not invent a second document database or local canonical copy.

Read `docs/API.md` for the exact endpoint contract. This file defines the client product shape and interaction priorities.

The reference implementation is a MoonBit JS package under `frontend/`, built by `make run` and served from the native backend at `/` and `/frontend.js`. Other clients may be Web, TUI, desktop, or agent-managed; they should preserve the same API and security behavior.

## Product Priorities

1. **Find and read documents quickly.** Navigation and search should remain usable before any editing features appear.
2. **Keep credentials deliberate.** API keys are secrets, not user profile data. Do not display or log them after entry.
3. **Preserve Markdown.** Editing writes the full raw Markdown source through `PUT`; do not silently transform syntax or strip content.
4. **Show the real server state.** A save only succeeds after a `200` response. Do not report optimistic completion before the request returns.
5. **Stay small.** This is a single-server, file-backed MVP, not a collaborative CMS.

## Capability Map

| Client capability | API / route | Required scope | Expected client behavior |
|---|---|---:|---|
| Public reading | `GET /d/{slug}` | none | Open rendered HTML in a browser or embedded web view |
| List document tree | `GET /api/v1/docs` | read | Build a hierarchical navigation tree from slash-separated slugs |
| Read raw Markdown | `GET /api/v1/docs/{slug}` | read | Fetch before editing; show source and optionally a preview |
| Search | `GET /api/v1/search?q=...` | read | Show matching slugs, then fetch the chosen document |
| Create / overwrite | `PUT /api/v1/docs/{slug}` | write | Send complete Markdown; show save success or server error |
| Delete | `DELETE /api/v1/docs/{slug}` | write | Require explicit confirmation, then refresh navigation |
| Read server config | `GET /api/v1/config` | read | Use title/description if present; provide a sensible fallback |
| Admin key management | `/admin/login`, `/admin/keys` | `ADMIN_TOKEN` | Prefer the server's existing browser page for MVP administration |

## Required States

Every interactive client should represent these states explicitly:

- **No API key:** read/write controls disabled; explain that a `read` or `read,write` key is needed.
- **Read-only key:** browsing and search enabled; editor may be visible but save/delete controls must be disabled.
- **Read/write key:** enable document creation, overwrite, and deletion.
- **Loading:** preserve prior document content while a replacement is loading; avoid a blank screen flicker.
- **401:** discard the current key from active use and request a replacement.
- **403:** keep the key but explain that its scope lacks write permission.
- **404:** distinguish an absent document from a network failure; offer to create it only with write scope.
- **Network failure:** show a retry action and do not claim a write succeeded.

## Web Client Shape

The recommended Web MVP has three regions, not a marketing landing page:

```text
+--------------------------------------------------------------+
| Site title | search field | connection / key status          |
+----------------------+---------------------------------------+
| Document tree        | Document workspace                    |
| - guide/             | title / slug                          |
|   - getting-started  | rendered preview or Markdown source    |
| - notes/             |                                       |
|                      | [Edit] [Save] [Delete]                |
+----------------------+---------------------------------------+
```

### Navigation

- Convert `guide/getting-started` into nested folders for presentation only; the slug remains the API identifier.
- Select `index` as the initial document if it exists.
- Keep search results separate from the permanent document tree.
- Do not infer ordering from filesystem timestamps; current list results are the server contract.

### Read Mode

- For simple public browsing, use `/d/{slug}` directly.
- For an authenticated client, use the raw Markdown API for source display and client-side preview.
- Mark rendered content as server content. Do not claim it is locally saved unless a write has returned `200`.

### Edit Mode

- Require `read,write` scope before enabling edits.
- Show the slug separately from the title. A slug must use only letters, numbers, `-`, `_`, and `/`; it may not contain empty segments, `.` or `..`.
- Fetch the current document before overwriting it whenever the user did not begin from a new-document flow.
- Use `PUT` for the entire Markdown body. There is no patch or conflict-resolution API in this MVP.
- On save failure, retain the editor buffer and show the server response.
- Delete requires a confirmation that includes the exact slug.

## TUI Client Shape

A TUI should prioritize the same workflow without reproducing a browser layout:

```text
[connection: read,write] [search: ____]

Documents                 Markdown
> index                   # Hello
  guide/                  ...
    getting-started

Commands: enter=open  e=edit  s=save  d=delete  /=search  q=quit
```

- Keep the active slug visible at all times.
- Use a modal or second pane for editing full Markdown.
- Treat destructive commands as confirmation flows, not immediate actions.
- Do not put API keys in command history or an on-screen status line.

## Credential Handling

- Let the operator provide base URL and API key through environment variables, an OS secret store, or an explicit settings input.
- Recommended names: `MBT_MDWIKI_URL` and `MBT_MDWIKI_KEY`.
- Never put keys in document text, screenshots, browser local storage by default, logs, or generated project files.
- Do not use `ADMIN_TOKEN` from a normal client. That token is for the server's local admin page only.

## Search Limits

The current search endpoint is intentionally basic:

- It is case-sensitive substring matching over slugs and raw Markdown.
- It has no ranking, snippets, pagination, semantic search, or vector index.
- Query handling currently does **not** percent-decode. Use plain ASCII query text without `&` or `=` until the server adds URL decoding.

A future client may expose semantic/vector search only after the server provides a stable endpoint. Do not fake a vector mode in the UI now.

## Non-Goals

Do not add these assumptions to a client brief or implementation without a new server design:

- Multi-user collaboration, cursors, comments, revisions, or merge conflicts
- Offline synchronization or a second document source of truth
- OAuth / third-party login
- MCP transport managed by the server
- Vector search, embeddings, or a vector database
- Direct filesystem access to the server's `content/` directory from a remote client
- A full visual CMS, drag-and-drop page builder, or WYSIWYG editor

## Acceptance Checklist For A Generated Client

A client is acceptable when it can demonstrate all of these against a local server:

1. Connect using a supplied base URL and API key.
2. List documents and open `index`.
3. Search for an ASCII word present in a document and open the result.
4. With a write key, create a new Markdown document, reread it, and delete it.
5. With a read-only key, visibly disable or reject save/delete.
6. Show a useful message for 401, 403, 404, and a network error.
7. Never print or persist the plaintext API key by default.
