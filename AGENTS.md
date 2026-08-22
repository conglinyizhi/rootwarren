# mbt-mdwiki Agent Guide

`mbt-mdwiki` is a MoonBit document backend. Markdown files under `content/` are the source of truth. The service exposes a protected REST API for agents and other clients to read, write, search, and delete documents.

## Scope

- Keep the server single-process and native-only.
- Do not add Docker, a database server, MCP server code, OAuth, or microservices.
- Use `content/` for documents and `meta/` for runtime JSON metadata.
- `meta/` is ignored by git. It contains API-key hashes and must not be committed.
- The public browser view is intentionally thin: `GET /d/{slug}` renders Markdown as HTML.

## Layout

- `content/`: Markdown source documents. A document slug is its relative path without `.md`.
- `meta/config.json`: runtime site configuration.
- `meta/api_keys.json`: API-key records. Plaintext keys are never stored.
- `storage.mbt`, `local_storage.mbt`: content-storage abstraction and local filesystem implementation.
- `meta_store.mbt`: JSON-backed config and API-key storage.
- `auth.mbt`: API-key generation and SHA-256 hashing.
- `cmd/main/main.mbt`: HTTP routes, API authentication, public rendering, and the small admin surface.
- `docs/API.md`: client-facing REST API contract.
- `scripts/demo.sh`: local end-to-end demonstration.

## Run And Verify

The current MoonBit nightly needs `MOON_CC=gcc` on this host because its automatic native archiver discovery selects an invalid path. The project `Makefile` exports it.

```sh
make check
PORT=8001 ADMIN_TOKEN=replace-me make run
```

`make run` builds the MoonBit JS client first, then starts the native server. The startup log prints the client URL (`/`), public document URL (`/d/index`), admin URL, and REST API URL. Use `make build-frontend` when only the browser bundle is needed.

- `PORT` defaults to `8001`.
- `ADMIN_TOKEN` is required for `/admin/*`; do not leave it unset in a public deployment.
- Use `make test` when tests exist. Run `moon fmt` after source changes.
- For the client shell check: `curl http://127.0.0.1:8001/`.
- For the public page check: `curl http://127.0.0.1:8001/d/index`.
- For protected API examples, see `docs/API.md`.
- The client bundle is built at `_build/js/debug/build/frontend/frontend.js`.

## API Security Model

- Clients authenticate with `Authorization: Bearer <api_key>`.
- Keys have `read` or `read,write` scopes.
- API-key plaintext is shown only on admin creation; only the SHA-256 hash is persisted.
- Use the admin page to create/revoke keys. It authenticates with `ADMIN_TOKEN` and an HttpOnly cookie.
- Do not log request authorization headers or generated plaintext keys.

## MoonBit Notes

- Code blocks are separated with `///|`.
- Package configuration is in `moon.pkg`; imports may declare an alias with `@alias`, and code references it with that `@alias` name.
- Discover current APIs with `moon ide doc`; the toolchain is nightly and exact APIs can move.
- MoonBit `String::to_bytes()` is not the encoding to use for interoperable API-key hashes. `auth.mbt` deliberately uses `@utf8.encode` before SHA-256.
