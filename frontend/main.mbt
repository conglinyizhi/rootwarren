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
  #|   const headers = {};
  #|   if (apiKey) headers.Authorization = `Bearer ${apiKey}`;
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
      _ => "ERR 0\n网络请求失败"
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
fn active_key(model : Model) -> String {
  model.api_key.trim().to_owned()
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
    content: "客户端已就绪。使用启动链接进入后，点击“加载文档”开始浏览。",
    status: "使用启动链接进入后，点击“加载文档”开始浏览。也可以手动输入访问 Key。",
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
          (
            { ..model, api_key, status: "访问 Key 已更新。" },
            @rabbita.none,
          )
        SetQuery(query) => ({ ..model, query, }, @rabbita.none)
        SetSlug(active_slug) => ({ ..model, active_slug, }, @rabbita.none)
        SetContent(content) => ({ ..model, content, }, @rabbita.none)
        LoadDocs =>
          (
            { ..model, busy: true, status: "正在加载文档……" },
            request_cmd(
              emit,
              ListDocs,
              "GET",
              "/api/v1/docs",
              active_key(model),
              "",
            ),
          )
        SelectDoc(slug) =>
          (
            {
              ..model,
              active_slug: slug,
              busy: true,
              status: "正在打开 \{slug}……",
            },
            request_cmd(
              emit,
              ReadDoc(slug),
              "GET",
              "/api/v1/docs/" + slug,
              active_key(model),
              "",
            ),
          )
        Search =>
          match search_url(model.query) {
            Some(url) =>
              (
                { ..model, busy: true, status: "正在搜索……" },
                request_cmd(emit, SearchDocs, "GET", url, active_key(model), ""),
              )
            None =>
              (
                {
                  ..model,
                  status: "请输入不含 & 或 = 的 ASCII 搜索词。",
                },
                @rabbita.none,
              )
          }
        NewDoc =>
          (
            {
              ..model,
              active_slug: "new-document",
              content: "# 新文档\n",
              status: "填写文档路径和 Markdown 正文后保存。",
            },
            @rabbita.none,
          )
        Save =>
          if model.active_slug.trim().is_empty() {
            ({ ..model, status: "请填写文档路径。" }, @rabbita.none)
          } else {
            (
              { ..model, busy: true, status: "正在保存……" },
              request_cmd(
                emit,
                SaveDoc,
                "PUT",
                "/api/v1/docs/" + model.active_slug.trim().to_owned(),
                active_key(model),
                model.content,
              ),
            )
          }
        Delete =>
          if model.active_slug.trim().is_empty() {
            (
              { ..model, status: "请先选择要删除的文档。" },
              @rabbita.none,
            )
          } else {
            (
              {
                ..model,
                busy: true,
                status: "正在删除 \{model.active_slug}……",
              },
              request_cmd(
                emit,
                DeleteDoc,
                "DELETE",
                "/api/v1/docs/" + model.active_slug.trim().to_owned(),
                active_key(model),
                "",
              ),
            )
          }
        RequestFinished(kind, ok, raw) =>
          if !ok {
            (
              { ..model, busy: false, status: "请求失败：\{raw}" },
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
                    status: "文档已加载。选择一篇开始阅读。",
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
                    status: "文档已打开。",
                  },
                  @rabbita.none,
                )
              SearchDocs =>
                (
                  {
                    ..model,
                    busy: false,
                    results: parse_string_array(raw, "results"),
                    status: "搜索完成。",
                  },
                  @rabbita.none,
                )
              SaveDoc =>
                (
                  {
                    ..model,
                    busy: false,
                    status: "已保存。需要时可重新加载文档刷新导航。",
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
                    status: "已删除。需要时可重新加载文档刷新导航。",
                  },
                  @rabbita.none,
                )
            }
          }
      }
    },
    view=fn(model, emit) {
      let write_disabled = model.busy
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
          h1("mbt-mdwiki 文档站"),
          input(
            input_type=Password,
            placeholder="访问 Key（仅保存在当前页面内存）",
            value=model.api_key,
            on_input=text => emit(SetApiKey(text)),
            attrs=named("api-key-input"),
          ),
          button(
            disabled=model.busy,
            on_click=emit(LoadDocs),
            attrs=named("load-documents-button"),
            "加载文档",
          ),
        ]),
        p(attrs=named("status-message"), model.status),
        div(class="workspace", [
          div(class="sidebar", attrs=named("document-navigation"), [
            h2("文档导航"),
            div(attrs=named("document-list"), document_buttons),
            h2("搜索文档"),
            input(
              input_type=Search,
              placeholder="输入关键词",
              value=model.query,
              on_input=text => emit(SetQuery(text)),
              attrs=named("search-input"),
            ),
            button(
              on_click=emit(Search),
              attrs=named("search-button"),
              "搜索",
            ),
            div(attrs=named("search-results"), result_buttons),
          ]),
          div(class="editor-panel", attrs=named("document-workspace"), [
            h2(
              if model.active_slug.is_empty() {
                "阅读文档"
              } else {
                model.active_slug
              },
            ),
            textarea(
              rows=24,
              placeholder="选择左侧文档后显示 Markdown 正文",
              value=model.content,
              on_input=text => emit(SetContent(text)),
              disabled=model.busy,
              attrs=named("markdown-editor"),
              @html.nothing,
            ),
            div(class="editor-actions", [
              input(
                placeholder="新建或重命名时填写路径，例如 guide/getting-started",
                value=model.active_slug,
                on_input=text => emit(SetSlug(text)),
                attrs=named("slug-input"),
              ),
              button(
                disabled=model.busy,
                on_click=emit(NewDoc),
                attrs=named("new-document-button"),
                "新建文档",
              ),
              button(
                disabled=write_disabled,
                on_click=emit(Save),
                attrs=named("save-document-button"),
                "保存",
              ),
              button(
                disabled=write_disabled,
                on_click=emit(Delete),
                attrs=named("delete-document-button"),
                "删除",
              ),
            ]),
          ]),
        ]),
      ])
    },
  )
  app.mount("app")
}
