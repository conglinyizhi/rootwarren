///|
using @html {button, div, h1, h2, input, p, textarea}

///|
enum RequestKind {
  ListDocs
  ReadDoc(String)
  SearchDocs
  SaveDoc
  DeleteDoc
}

///|
enum Msg {
  SetApiKey(String)
  SetQuery(String)
  SetSlug(String)
  SetContent(String)
  LoadDocs
  SelectDoc(String)
  Search
  NewDoc
  Save
  Delete
  RequestFinished(RequestKind, Bool, String)
}

///|
struct Model {
  api_key : String
  query : String
  slugs : Array[String]
  results : Array[String]
  active_slug : String
  content : String
  status : String
  busy : Bool
} derive(Eq)

///|
fn named(name : String) -> @html.Attrs {
  @html.Attrs::build().data_set("name", name)
}

///|
extern "js" fn fetch_text(
  verb : String,
  url : String,
  api_key : String,
  body : String,
) -> @js.Promise =
  #| (verb, url, apiKey, body) => {
  #|   const headers = { Authorization: `Bearer ${apiKey}` };
  #|   if (verb === "PUT") headers["Content-Type"] = "text/markdown";
  #|   const options = { method: verb, headers };
  #|   if (verb === "PUT") options.body = body;
  #|   return fetch(url, options).then(async (response) => {
  #|     const text = await response.text();
  #|     return (response.ok ? "OK\n" : `ERR ${response.status}\n`) + text;
  #|   });
  #| }

///|
async fn call_api(
  verb : String,
  url : String,
  api_key : String,
  body : String,
) -> (Bool, String) noraise {
  let raw : String = fetch_text(verb, url, api_key, body).wait().cast() catch {
      _ => "ERR 0\nNetwork request failed"
    }
  if raw.has_prefix("OK\n") {
    (true, raw[3:].to_owned())
  } else {
    (false, raw[4:].to_owned())
  }
}

///|
fn request_cmd(
  emit : @rabbita.Emit[Msg],
  kind : RequestKind,
  verb : String,
  url : String,
  api_key : String,
  body : String,
) -> @rabbita.Cmd {
  @rabbita.perform(
    (result : (Bool, String)) => emit(RequestFinished(kind, result.0, result.1)),
    async fn() noraise { call_api(verb, url, api_key, body) },
  )
}

///|
fn parse_string_array(raw : String, field : String) -> Array[String] {
  let json = @json.parse(raw) catch { _ => return [] }
  let result : Array[String] = []
  if json is Object(object) {
    if object.get(field) is Some(Array(items)) {
      for item in items {
        if item is String(value) {
          result.push(value)
        }
      }
    }
  }
  result
}

///|
fn require_key(model : Model) -> String? {
  if model.api_key.trim().is_empty() {
    None
  } else {
    Some(model.api_key.trim().to_owned())
  }
}

///|
fn search_url(query : String) -> String? {
  let query = query.trim()
  if query.is_empty() || query.contains("&") || query.contains("=") {
    None
  } else {
    Some("/api/v1/search?q=" + query.to_owned())
  }
}

///|
fn initial_model() -> Model {
  {
    api_key: "",
    query: "",
    slugs: [],
    results: [],
    active_slug: "",
    content: "",
    status: "Enter a read or read,write API key, then load documents.",
    busy: false,
  }
}

///|
fn main {
  let app = @rabbita.elmish(
    model=initial_model(),
    update=fn(model, msg, emit) {
      match msg {
        SetApiKey(api_key) =>
          ({ ..model, api_key, status: "API key changed." }, @rabbita.none)
        SetQuery(query) => ({ ..model, query, }, @rabbita.none)
        SetSlug(active_slug) => ({ ..model, active_slug, }, @rabbita.none)
        SetContent(content) => ({ ..model, content, }, @rabbita.none)
        LoadDocs =>
          match require_key(model) {
            None =>
              (
                { ..model, status: "A read or read,write API key is required." },
                @rabbita.none,
              )
            Some(key) =>
              (
                { ..model, busy: true, status: "Loading documents..." },
                request_cmd(emit, ListDocs, "GET", "/api/v1/docs", key, ""),
              )
          }
        SelectDoc(slug) =>
          match require_key(model) {
            None =>
              (
                { ..model, status: "A read API key is required." },
                @rabbita.none,
              )
            Some(key) =>
              (
                {
                  ..model,
                  active_slug: slug,
                  busy: true,
                  status: "Loading \\{slug}...",
                },
                request_cmd(
                  emit,
                  ReadDoc(slug),
                  "GET",
                  "/api/v1/docs/" + slug,
                  key,
                  "",
                ),
              )
          }
        Search =>
          match (require_key(model), search_url(model.query)) {
            (Some(key), Some(url)) =>
              (
                { ..model, busy: true, status: "Searching..." },
                request_cmd(emit, SearchDocs, "GET", url, key, ""),
              )
            (None, _) =>
              (
                { ..model, status: "A read API key is required." },
                @rabbita.none,
              )
            (_, None) =>
              (
                {
                  ..model,
                  status: "Use a nonempty ASCII search term without & or =.",
                },
                @rabbita.none,
              )
          }
        NewDoc =>
          (
            {
              ..model,
              active_slug: "new-document",
              content: "# New document\\n",
              status: "Choose a slug, then save.",
            },
            @rabbita.none,
          )
        Save =>
          match require_key(model) {
            None =>
              (
                { ..model, status: "A read,write API key is required to save." },
                @rabbita.none,
              )
            Some(key) =>
              if model.active_slug.trim().is_empty() {
                (
                  { ..model, status: "A document slug is required." },
                  @rabbita.none,
                )
              } else {
                (
                  { ..model, busy: true, status: "Saving..." },
                  request_cmd(
                    emit,
                    SaveDoc,
                    "PUT",
                    "/api/v1/docs/" + model.active_slug.trim().to_owned(),
                    key,
                    model.content,
                  ),
                )
              }
          }
        Delete =>
          match require_key(model) {
            None =>
              (
                {
                  ..model,
                  status: "A read,write API key is required to delete.",
                },
                @rabbita.none,
              )
            Some(key) =>
              if model.active_slug.trim().is_empty() {
                (
                  { ..model, status: "Choose a document before deleting." },
                  @rabbita.none,
                )
              } else {
                (
                  {
                    ..model,
                    busy: true,
                    status: "Deleting \\{model.active_slug}...",
                  },
                  request_cmd(
                    emit,
                    DeleteDoc,
                    "DELETE",
                    "/api/v1/docs/" + model.active_slug.trim().to_owned(),
                    key,
                    "",
                  ),
                )
              }
          }
        RequestFinished(kind, ok, raw) =>
          if !ok {
            (
              { ..model, busy: false, status: "Request failed: \\{raw}" },
              @rabbita.none,
            )
          } else {
            match kind {
              ListDocs =>
                (
                  {
                    ..model,
                    busy: false,
                    slugs: parse_string_array(raw, "docs"),
                    status: "Documents loaded.",
                  },
                  @rabbita.none,
                )
              ReadDoc(slug) =>
                (
                  {
                    ..model,
                    busy: false,
                    active_slug: slug,
                    content: raw,
                    status: "Document loaded.",
                  },
                  @rabbita.none,
                )
              SearchDocs =>
                (
                  {
                    ..model,
                    busy: false,
                    results: parse_string_array(raw, "results"),
                    status: "Search complete.",
                  },
                  @rabbita.none,
                )
              SaveDoc =>
                (
                  {
                    ..model,
                    busy: false,
                    status: "Saved. Reload documents to refresh the tree.",
                  },
                  @rabbita.none,
                )
              DeleteDoc =>
                (
                  {
                    ..model,
                    busy: false,
                    active_slug: "",
                    content: "",
                    status: "Deleted. Reload documents to refresh the tree.",
                  },
                  @rabbita.none,
                )
            }
          }
      }
    },
    view=fn(model, emit) {
      let write_disabled = model.busy || model.api_key.trim().is_empty()
      let document_buttons = model.slugs.map(fn(slug) {
        button(
          class="document-button",
          on_click=emit(SelectDoc(slug)),
          attrs=named("document-list-item"),
          slug,
        )
      })
      let result_buttons = model.results.map(fn(slug) {
        button(
          class="result-button",
          on_click=emit(SelectDoc(slug)),
          attrs=named("search-result-item"),
          slug,
        )
      })
      div(class="client-shell", attrs=named("client-shell"), [
        div(class="client-header", [
          h1("mbt-mdwiki"),
          input(
            input_type=Password,
            placeholder="API key (kept in memory)",
            value=model.api_key,
            on_input=text => emit(SetApiKey(text)),
            attrs=named("api-key-input"),
          ),
          button(
            disabled=model.busy,
            on_click=emit(LoadDocs),
            attrs=named("load-documents-button"),
            "Load documents",
          ),
        ]),
        p(attrs=named("status-message"), model.status),
        div(class="workspace", [
          div(class="sidebar", attrs=named("document-navigation"), [
            h2("Documents"),
            button(
              on_click=emit(NewDoc),
              attrs=named("new-document-button"),
              "New document",
            ),
            div(attrs=named("document-list"), document_buttons),
            h2("Search"),
            input(
              input_type=Search,
              placeholder="ASCII keyword",
              value=model.query,
              on_input=text => emit(SetQuery(text)),
              attrs=named("search-input"),
            ),
            button(
              on_click=emit(Search),
              attrs=named("search-button"),
              "Search",
            ),
            div(attrs=named("search-results"), result_buttons),
          ]),
          div(class="editor-panel", attrs=named("document-workspace"), [
            input(
              placeholder="slug, e.g. guide/getting-started",
              value=model.active_slug,
              on_input=text => emit(SetSlug(text)),
              attrs=named("slug-input"),
            ),
            textarea(
              rows=24,
              placeholder="Markdown source",
              value=model.content,
              on_input=text => emit(SetContent(text)),
              disabled=model.busy,
              attrs=named("markdown-editor"),
              @html.nothing,
            ),
            div(class="editor-actions", [
              button(
                disabled=write_disabled,
                on_click=emit(Save),
                attrs=named("save-document-button"),
                "Save",
              ),
              button(
                disabled=write_disabled,
                on_click=emit(Delete),
                attrs=named("delete-document-button"),
                "Delete",
              ),
            ]),
          ]),
        ]),
      ])
    },
  )
  app.mount("app")
}
