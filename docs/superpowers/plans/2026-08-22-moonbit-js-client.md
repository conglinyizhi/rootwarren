# MoonBit JS Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a MoonBit JS web client that lets an operator browse, search, read, edit, create, and delete mbt-mdwiki documents through the existing REST API.

**Architecture:** Add a `frontend/` MoonBit package compiled for the JS target. The native HTTP server serves the frontend HTML shell at `/` and the generated `frontend.js` bundle at `/frontend.js`, while the browser client calls the existing `/api/v1/*` API on the same origin. API keys remain browser-session state and are never sent to the server except in the Authorization header for API calls.

**Tech Stack:** MoonBit JS target, `moonbit-community/rabbita`, `moonbitlang/core/json`, existing `moonbitlang/async` native server, CommonMark public renderer.

## Global Constraints

- Keep one native server process; do not add Docker, a separate frontend server, OAuth, MCP server code, or a database.
- Keep `content/` as document source of truth and `meta/` as runtime JSON metadata.
- API keys must never be logged, embedded into source, committed, or persisted by default.
- Reuse the documented `/api/v1/*` contract only; do not invent vector search, patches, revisions, or collaboration behavior.
- Important browser controls must carry stable `data-name` attributes.
- Build target is current MoonBit nightly. Use `moon ide doc` for exact APIs and `MOON_CC=gcc` for native build/run through the Makefile.

---

### Task 1: Define and build the JS frontend package

**Files:**
- Create: `frontend/moon.pkg`
- Create: `frontend/main.mbt`
- Modify: `moon.mod`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `GET /api/v1/docs`, `GET /api/v1/docs/{slug}`, `PUT /api/v1/docs/{slug}`, `DELETE /api/v1/docs/{slug}`, `GET /api/v1/search?q={query}`.
- Produces: `_build/js/release/build/frontend/frontend.js` (exact output path confirmed during implementation).

- [ ] Add `moonbit-community/rabbita` as a module dependency and import its UI/HTTP packages in `frontend/moon.pkg` with `supported_targets = "js"` and `pkgtype(kind: "executable")`.
- [ ] Define an explicit application model: API key, document slugs, active slug, raw Markdown, query, search results, current view, busy state, and status/error message.
- [ ] Implement messages for key editing, listing documents, selecting a document, searching, editing Markdown, save, create, delete, and request results.
- [ ] Build `frontend` with `moon build frontend --target js` and record the actual bundle output location.
- [ ] Commit the package setup and independently buildable client skeleton.

### Task 2: Implement the operator client UI

**Files:**
- Modify: `frontend/main.mbt`

**Interfaces:**
- Consumes: the frontend model and update messages from Task 1.
- Produces: browser controls tagged with `data-name` and API calls carrying `Authorization: Bearer <key>`.

- [ ] Render a compact operational layout: credential entry and status header, document/navigation panel, search area, Markdown editor, preview/read panel, and explicit create/save/delete actions.
- [ ] Disable write actions without a `read,write` key; retain read/search behavior for `read` keys.
- [ ] Keep the API key only in runtime client model state; never render it as normal content or persist it to local storage.
- [ ] Map HTTP 401, 403, 404, and transport failures to specific user-visible status text.
- [ ] Add `data-name` to all inputs, document list items, search, and command buttons.
- [ ] Rebuild the JS bundle and inspect the browser console/network behavior manually.
- [ ] Commit the working client interaction layer.

### Task 3: Serve the client from the native backend

**Files:**
- Modify: `cmd/main/main.mbt`
- Modify: `cmd/main/moon.pkg`
- Create: `frontend/index.html`
- Modify: `Makefile`

**Interfaces:**
- Consumes: built `frontend.js` from Task 1 and browser requests to `/` and `/frontend.js`.
- Produces: `GET /` HTML shell and `GET /frontend.js` JavaScript bundle from the same native origin as `/api/v1/*`.

- [ ] Add public `GET /` route returning the HTML shell containing `<div id="app"></div>` and `<script src="/frontend.js"></script>`.
- [ ] Add public `GET /frontend.js` route that streams the generated JS bundle with `application/javascript`; return a direct build instruction when missing.
- [ ] Add `make build-frontend` and make `run` depend on the JS bundle so a standard `make run` serves a working client.
- [ ] Keep `/d/{slug}`, `/admin/*`, `/health`, and `/api/v1/*` behavior intact.
- [ ] Commit server/static resource integration.

### Task 4: Verify the full client workflow and document it

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/CLIENT.md`
- Modify: `docs/API.md`
- Modify: `scripts/demo.sh` if needed

**Interfaces:**
- Consumes: complete frontend and native server from Tasks 1–3.
- Produces: reproducible launch and verification commands.

- [ ] Run `moon check`, `moon test`, `moon info`, and `make build-frontend`.
- [ ] Start `ADMIN_TOKEN=... make run`, request `/`, `/frontend.js`, and `/health`; verify content types and nonempty bundle output.
- [ ] Use browser tooling or direct API setup to confirm that a supplied read/write key lists, reads, writes, searches, and deletes a document through the rendered client.
- [ ] Update documentation with the frontend build/run workflow and clarify that the API key is in-memory client state.
- [ ] Run `git diff --check`, inspect generated interface changes, and commit verification/documentation updates.

## Self-Review

- Spec coverage: the plan implements the CLIENT.md capability map without adding excluded OAuth, MCP, vector search, collaboration, revisions, or a second document store.
- Placeholder scan: every task lists concrete files, API surfaces, build commands, and verification output.
- Type consistency: browser client uses existing REST routes and Bearer API key format; native server continues to own all API endpoints and static bundle delivery.
