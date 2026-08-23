// 共享前端组件包（js+native+wasm）。
// 纯 UI：数据一律通过后端 REST API 获取，不 import 任何 native 库层，
// 这样同一份组件既能被浏览器水合，也能被后端 SSR 渲染。
//
// 前台文档阅读页：文档列表 + 阅读区（Markdown HTML via inner_html）+ 搜索。

///|
using @rabbita {type Val, type Html, type Cmd, type Emit}

///|
using @html {body, button, div, h1, h2, head, html, input, link, p, title}


///|
pub enum Msg {
  LoadConfig
  LoadDocs
  SelectDoc(String)
  SetQuery(String)
  ConfigLoaded(String)
  DocsLoaded(Result[String, Error])
  DocLoaded(String, Result[String, Error])
}

///|
pub struct Model {
  title : String
  slugs : Array[String]
  active_slug : String
  active_html : String
  query : String
  status : String
  busy : Bool
} derive(Eq)

///|
pub fn initial_model() -> Model {
  {
    title: "mbt-mdwiki",
    slugs: [],
    active_slug: "",
    active_html: "",
    query: "",
    status: "点击左侧文档开始阅读。",
    busy: false,
  }
}

///|
fn parse_slugs(raw : String) -> Array[String] {
  let json = @json.parse(raw) catch { _ => return [] }
  let result : Array[String] = []
  if json is Json::Object(map) {
    if map.get("docs") is Some(Json::Array(items)) {
      for item in items {
        if item is Json::String(value) {
          result.push(value)
        }
      }
    }
  }
  result
}

///|
fn parse_html(raw : String) -> String {
  let json = @json.parse(raw) catch { _ => return "" }
  match json {
    Json::Object(map) => match map.get("html") {
      Some(Json::String(html)) => html
      _ => ""
    }
    _ => ""
  }
}

///|
fn parse_title(raw : String) -> String {
  let json = @json.parse(raw) catch { _ => return "mbt-mdwiki" }
  match json {
    Json::Object(map) => match map.get("title") {
      Some(Json::String(title)) => title
      _ => "mbt-mdwiki"
    }
    _ => "mbt-mdwiki"
  }
}

///|
pub fn update(model : Model, msg : Msg, emit : Emit[Msg]) -> (Model, Cmd) {
  match msg {
    LoadConfig =>
      (
        model,
        @http.get("/api/v1/config").expect_text(emit.map(result => {
          match result {
            Ok(raw) => ConfigLoaded(parse_title(raw))
            Err(_) => ConfigLoaded("mbt-mdwiki")
          }
        })),
      )
    ConfigLoaded(title) => ({ ..model, title }, @rabbita.none)
    LoadDocs =>
      (
        { ..model, busy: true, status: "正在加载文档……" },
        @rabbita.batch([
          @http.get("/api/v1/docs").expect_text(emit.map(result => DocsLoaded(result))),
          @http.get("/api/v1/config").expect_text(emit.map(result => {
            match result {
              Ok(raw) => ConfigLoaded(parse_title(raw))
              Err(_) => ConfigLoaded("mbt-mdwiki")
            }
          })),
        ]),
      )
    SelectDoc(slug) =>
      (
        { ..model, busy: true, status: "正在打开 " + slug + "……" },
        @http.get("/api/v1/docs/" + slug).expect_text(emit.map(result => DocLoaded(slug, result))),
      )
    SetQuery(query) => ({ ..model, query }, @rabbita.none)
    DocsLoaded(result) =>
      (
        {
          ..model,
          busy: false,
          slugs: match result {
            Ok(raw) => parse_slugs(raw)
            Err(_) => []
          },
          status: match result {
            Ok(_) => "文档已加载。选择一篇开始阅读。"
            Err(_) => "文档加载失败。"
          },
        },
        @rabbita.none,
      )
    DocLoaded(slug, result) =>
      (
        {
          ..model,
          busy: false,
          active_slug: slug,
          active_html: match result {
            Ok(raw) => parse_html(raw)
            Err(_) => ""
          },
          status: match result {
            Ok(_) => "已打开 " + slug + "。"
            Err(_) => "打开文档失败。"
          },
        },
        @rabbita.none,
      )
  }
}

///|
/// 根组件：返回完整 HTML 结构，SSR 与浏览器水合共用。
pub fn app() -> Val[Html] {
  let (model, emit) = @rabbita.create_state(initial_model(), update~)
  model.view(model => {
    let doc_buttons = model.slugs.map(fn(slug) {
      button(
        class="document-button",
        on_click=emit(SelectDoc(slug)),
        attrs=@html.Attrs::build().data_set("name", "document-list-item"),
        slug,
      )
    })
    html <| [
      head([
        link(rel="stylesheet", href="/site.css"),
        title(model.title),
      ]),
      body <| [
        div(class="reading-shell") <| [
          div(class="topbar", [
            h1(model.title + " 文档站"),
            button(
              class="button",
              on_click=emit(LoadDocs),
              attrs=@html.Attrs::build().data_set("name", "load-documents-button"),
              "加载文档",
            ),
            input(
              input_type=@html.InputType::Search,
              placeholder="搜索文档",
              value=model.query,
              on_input=text => emit(SetQuery(text)),
              attrs=@html.Attrs::build().data_set("name", "search-input"),
            ),
          ]),
          p(model.status),
          div(class="workspace", [
            div(class="sidebar", [
              h2("文档导航"),
              p(model.slugs.length().to_string() + " 篇文档"),
              div(attrs=@html.Attrs::build().data_set("name", "document-list"), doc_buttons),
            ]),
            div(class="editor-panel", [
              h2(if model.active_slug.is_empty() { "阅读文档" } else { model.active_slug }),
              div(
                attrs=@html.Attrs::build().data_set("name", "document-content").inner_html(model.active_html),
                @html.nothing,
              ),
            ]),
          ]),
        ],
      ],
    ]
  })
}
