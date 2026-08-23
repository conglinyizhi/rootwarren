// 共享前端组件包（js+native+wasm）。
// 纯 UI：数据一律通过后端 REST API 获取，不 import 任何 native 库层。
// 认证走 cookie session（moonback 设置 HttpOnly cookie），浏览器 fetch 自动携带，
// 因此写接口无需手动带 Authorization header。
//
// 前台文档站：文档列表 + 阅读(Markdown HTML via inner_html) + 登录 + 编辑/保存/删除。
// active_html 只接收服务端 CMark 渲染结果；这里是受控的 Markdown HTML 边界。

///|
using @rabbita {type Val, type Html, type Cmd, type Emit}

///|
using @html {
  a,
  body,
  details,
  button,
  div,
  h1,
  h2,
  h3,
  h4,
  head,
  html,
  input,
  label,
  li,
  link,
  option,
  p,
  section,
  select,
  span,
  summary,
  textarea,
  title,
  ul,
}

///|
pub enum Msg {
  Init
  LoadDocs
  SelectDoc(String)
  SetQuery(String)
  Logout
  Edit
  SetContent(String)
  Save
  Delete
  ConfigLoaded(String)
  DocsLoaded(Result[String, Error])
  DocLoaded(String, Result[String, Error])
  MeLoaded(String)
  SaveDone(Result[String, Error])
  DeleteDone(Result[String, Error])
  // 后台管理
  ShowAdmin
  HideAdmin
  AdminUsersLoaded(Result[String, Error])
  AdminSiteLoaded(Result[String, Error])
  SetSiteTitle(String)
  SaveSite
  SiteSaved(Result[String, Error])
  // API key 管理
  AdminKeysLoaded(Result[String, Error])
  SetKeyName(String)
  SetKeyScopes(String)
  SetKeyReadPrefix(String)
  SetKeyWritePrefix(String)
  CreateKey
  KeyCreated(Result[String, Error])
  // 分类管理
  AdminCategoriesLoaded(Result[String, Error])
  // 主题切换（system/light/dark），只存浏览器
  SetTheme(String)
}

///|
pub struct Model {
  title : String
  slugs : Array[String]
  active_slug : String
  active_title : String
  active_html : String
  query : String
  status : String
  busy : Bool
  loaded : Bool
  // 认证与编辑
  authed : Bool
  editing : Bool
  content : String
  // 后台管理
  admin_view : Bool
  users : Array[String]
  site_title_input : String
  keys : Array[String]
  key_name : String
  key_scopes : String
  key_read_prefix : String
  key_write_prefix : String
  categories : Array[String]
  active_category : String
  active_status : String
  theme : String
} derive(Eq)

///|
pub extend Model with Eq::{not_equal, equal}

///|
/// 站点配置请求体。
pub struct SitePayload {
  title : String
  public : String
  show_tree : String
  llms_mode : String
  llms_prefixes : String
} derive(ToJson)

///|
pub extend SitePayload with ToJson::{to_json}

///|
/// API key 创建请求体。
pub struct KeyPayload {
  name : String
  scopes : String
  read_prefix : String
  write_prefix : String
} derive(ToJson)

///|
pub extend KeyPayload with ToJson::{to_json}

///|
pub fn initial_model() -> Model {
  {
    title: "mbt-mdwiki",
    slugs: [],
    active_slug: "",
    active_title: "",
    active_html: "",
    query: "",
    status: "",
    busy: false,
    loaded: false,
    authed: false,
    editing: false,
    content: "",
    admin_view: false,
    users: [],
    site_title_input: "",
    keys: [],
    key_name: "",
    key_scopes: "read",
    key_read_prefix: "",
    key_write_prefix: "",
    categories: [],
    active_category: "",
    active_status: "",
    theme: "system",
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
    Json::Object(map) =>
      match map.get("html") {
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
    Json::Object(map) =>
      match map.get("title") {
        Some(Json::String(title)) => title
        _ => "mbt-mdwiki"
      }
    _ => "mbt-mdwiki"
  }
}

///|
fn parse_users(raw : String) -> Array[String] {
  let json = @json.parse(raw) catch { _ => return [] }
  let result : Array[String] = []
  if json is Json::Object(map) {
    if map.get("users") is Some(Json::Array(items)) {
      for item in items {
        if item is Json::Object(u) {
          result.push(
            match u.get("username") {
              Some(Json::String(name)) => name
              _ => ""
            },
          )
        }
      }
    }
  }
  result
}

///|
fn parse_site_title(raw : String) -> String {
  let json = @json.parse(raw) catch { _ => return "mbt-mdwiki" }
  match json {
    Json::Object(map) =>
      match map.get("title") {
        Some(Json::String(title)) => title
        _ => "mbt-mdwiki"
      }
    _ => "mbt-mdwiki"
  }
}

///|
fn parse_keys(raw : String) -> Array[String] {
  let json = @json.parse(raw) catch { _ => return [] }
  let result : Array[String] = []
  if json is Json::Object(map) {
    if map.get("keys") is Some(Json::Array(items)) {
      for item in items {
        if item is Json::Object(k) {
          result.push(
            match k.get("name") {
              Some(Json::String(name)) => name
              _ => ""
            },
          )
        }
      }
    }
  }
  result
}

///|
fn extract_key(raw : String) -> String {
  let json = @json.parse(raw) catch { _ => return "" }
  match json {
    Json::Object(map) =>
      match map.get("key") {
        Some(Json::String(k)) => k
        _ => ""
      }
    _ => ""
  }
}

///|
fn parse_categories(raw : String) -> Array[String] {
  let json = @json.parse(raw) catch { _ => return [] }
  let result : Array[String] = []
  if json is Json::Object(map) {
    if map.get("categories") is Some(Json::Array(items)) {
      for item in items {
        if item is Json::Object(c) {
          result.push(
            match c.get("name") {
              Some(Json::String(name)) => name
              _ => ""
            },
          )
        }
      }
    }
  }
  result
}

///|
fn parse_field(raw : String, field : String) -> String {
  let json = @json.parse(raw) catch { _ => return "" }
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::String(v)) => v
        _ => ""
      }
    _ => ""
  }
}

///|
fn load_docs_cmd(emit : Emit[Msg]) -> Cmd {
  @rabbita.batch([
    @http.get("/api/v1/docs").expect_text(
      emit.map(result => DocsLoaded(result)),
    ),
    @http.get("/api/v1/config").expect_text(
      emit.map(result => {
        ConfigLoaded(
          match result {
            Ok(raw) => parse_title(raw)
            Err(_) => "mbt-mdwiki"
          },
        )
      }),
    ),
    @http.get("/api/auth/me").expect_text(
      emit.map(result => {
        MeLoaded(
          match result {
            Ok(_) => "authed"
            Err(_) => "anon"
          },
        )
      }),
    ),
  ])
}

///|
pub fn update(model : Model, msg : Msg, emit : Emit[Msg]) -> (Model, Cmd) {
  match msg {
    Init =>
      (
        { ..model, loaded: true, busy: true, status: "正在加载……" },
        @rabbita.batch([
          load_docs_cmd(emit),
          @http.get("/api/v1/docs/index").expect_text(
            emit.map(result => DocLoaded("index", result)),
          ),
        ]),
      )
    LoadDocs =>
      (
        { ..model, busy: true, status: "正在加载文档……" },
        load_docs_cmd(emit),
      )
    SelectDoc(slug) =>
      (
        {
          ..model,
          busy: true,
          status: "正在打开 " + slug + "……",
          editing: false,
        },
        @http.get("/api/v1/docs/" + slug).expect_text(
          emit.map(result => DocLoaded(slug, result)),
        ),
      )
    SetQuery(query) => ({ ..model, query, }, @rabbita.none)
    Logout =>
      (
        { ..model, busy: true, status: "正在退出……" },
        @http.post("/api/auth/logout").expect_text(
          emit.map(_result => MeLoaded("anon")),
        ),
      )
    Edit =>
      ({ ..model, editing: true, content: model.active_html }, @rabbita.none)
    SetContent(content) => ({ ..model, content, }, @rabbita.none)
    Save =>
      (
        { ..model, busy: true, status: "正在保存……" },
        @http.put("/api/v1/docs/" + model.active_slug)
        .with_text(model.content)
        .expect_text(emit.map(result => SaveDone(result))),
      )
    Delete =>
      (
        { ..model, busy: true, status: "正在删除……" },
        @http.delete("/api/v1/docs/" + model.active_slug).expect_text(
          emit.map(result => DeleteDone(result)),
        ),
      )
    ConfigLoaded(title) => ({ ..model, title, }, @rabbita.none)
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
            Ok(raw) =>
              "已加载 " +
              parse_slugs(raw).length().to_string() +
              " 篇文档。"
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
          active_title: match result {
            Ok(raw) => parse_title(raw)
            Err(_) => slug
          },
          active_category: match result {
            Ok(raw) => parse_field(raw, "category")
            Err(_) => ""
          },
          active_status: match result {
            Ok(raw) => parse_field(raw, "status")
            Err(_) => ""
          },
          status: match result {
            Ok(_) => "打开「" + slug + "」。"
            Err(_) => "打开文档失败。"
          },
        },
        @rabbita.none,
      )
    MeLoaded(kind) =>
      ({ ..model, authed: kind == "authed", busy: false }, @rabbita.none)
    SaveDone(result) =>
      (
        {
          ..model,
          busy: false,
          editing: false,
          status: match result {
            Ok(_) => "已保存。"
            Err(_) => "保存失败：需要登录且有写权限。"
          },
        },
        @rabbita.none,
      )
    DeleteDone(result) =>
      (
        {
          ..model,
          busy: false,
          active_slug: "",
          active_html: "",
          status: match result {
            Ok(_) => "已删除。"
            Err(_) => "删除失败。"
          },
        },
        @rabbita.none,
      )
    ShowAdmin =>
      (
        {
          ..model,
          admin_view: true,
          busy: true,
          status: "正在加载后台数据……",
        },
        @rabbita.batch([
          @http.get("/api/admin/users").expect_text(
            emit.map(result => AdminUsersLoaded(result)),
          ),
          @http.get("/api/admin/site").expect_text(
            emit.map(result => AdminSiteLoaded(result)),
          ),
          @http.get("/api/admin/keys").expect_text(
            emit.map(result => AdminKeysLoaded(result)),
          ),
          @http.get("/api/v1/categories").expect_text(
            emit.map(result => AdminCategoriesLoaded(result)),
          ),
        ]),
      )
    HideAdmin => ({ ..model, admin_view: false }, @rabbita.none)
    SetTheme(t) => ({ ..model, theme: t }, @rabbita.none)
    AdminUsersLoaded(result) =>
      (
        {
          ..model,
          busy: false,
          users: match result {
            Ok(raw) => parse_users(raw)
            Err(_) => []
          },
          status: match result {
            Ok(_) => "后台已加载。"
            Err(_) => "后台加载失败：需要管理员权限。"
          },
        },
        @rabbita.none,
      )
    AdminSiteLoaded(result) =>
      (
        {
          ..model,
          site_title_input: match result {
            Ok(raw) => parse_site_title(raw)
            Err(_) => model.title
          },
        },
        @rabbita.none,
      )
    SetSiteTitle(t) => ({ ..model, site_title_input: t }, @rabbita.none)
    SaveSite =>
      (
        { ..model, busy: true, status: "正在保存站点设置……" },
        @http.post("/api/admin/site")
        .with_json(SitePayload::{
          title: model.site_title_input,
          public: "true",
          show_tree: "true",
          llms_mode: "public",
          llms_prefixes: "",
        })
        .expect_text(emit.map(result => SiteSaved(result))),
      )
    SiteSaved(result) =>
      (
        {
          ..model,
          busy: false,
          title: model.site_title_input,
          status: match result {
            Ok(_) => "站点设置已保存。"
            Err(_) => "保存失败。"
          },
        },
        @rabbita.none,
      )
    AdminKeysLoaded(result) =>
      (
        {
          ..model,
          busy: false,
          keys: match result {
            Ok(raw) => parse_keys(raw)
            Err(_) => []
          },
        },
        @rabbita.none,
      )
    AdminCategoriesLoaded(result) =>
      (
        {
          ..model,
          busy: false,
          categories: match result {
            Ok(raw) => parse_categories(raw)
            Err(_) => []
          },
        },
        @rabbita.none,
      )
    SetKeyName(n) => ({ ..model, key_name: n }, @rabbita.none)
    SetKeyScopes(s) => ({ ..model, key_scopes: s }, @rabbita.none)
    SetKeyReadPrefix(p) => ({ ..model, key_read_prefix: p }, @rabbita.none)
    SetKeyWritePrefix(p) => ({ ..model, key_write_prefix: p }, @rabbita.none)
    CreateKey =>
      (
        { ..model, busy: true, status: "正在创建 API key……" },
        @http.post("/api/admin/keys")
        .with_json(KeyPayload::{
          name: model.key_name,
          scopes: model.key_scopes,
          read_prefix: model.key_read_prefix,
          write_prefix: model.key_write_prefix,
        })
        .expect_text(emit.map(result => KeyCreated(result))),
      )
    KeyCreated(result) =>
      (
        {
          ..model,
          busy: false,
          key_name: "",
          status: match result {
            Ok(raw) => "API key 已创建：" + extract_key(raw)
            Err(_) => "创建失败。"
          },
        },
        @rabbita.none,
      )
  }
}

///|
/// 根组件：返回完整 HTML 结构，SSR 与浏览器水合共用。
#warnings("-alert_xss_vulnerable")
pub fn app() -> Val[Html] {
  let (model, emit) = @rabbita.create_state(initial_model(), update~, subscriptions=(
    model,
    emit,
    // 组件挂载后自动加载：首次触发 Init（打开 index + 拉列表）
  ) => if model.loaded { @sub.batch([]) } else { @sub.every(60, emit(Init)) })
  model.view(model => {
    let doc_buttons = model.slugs.map(fn(slug) {
      button(
        class="document-button",
        on_click=emit(SelectDoc(slug)),
        attrs=@html.Attrs::build().data_set("name", "document-list-item"),
        slug,
      )
    })
    let theme_switch = div(class="theme-switch", [
      button(
        class=if model.theme == "system" { "active" } else { "" },
        on_click=emit(SetTheme("system")),
        attrs=@html.Attrs::build()
          .data_set("theme-apply", "system")
          .data_set("name", "theme-system"),
        "系统",
      ),
      button(
        class=if model.theme == "light" { "active" } else { "" },
        on_click=emit(SetTheme("light")),
        attrs=@html.Attrs::build()
          .data_set("theme-apply", "light")
          .data_set("name", "theme-light"),
        "浅色",
      ),
      button(
        class=if model.theme == "dark" { "active" } else { "" },
        on_click=emit(SetTheme("dark")),
        attrs=@html.Attrs::build()
          .data_set("theme-apply", "dark")
          .data_set("name", "theme-dark"),
        "深色",
      ),
    ])
    let auth_ui = if model.authed {
      div(class="auth-bar", [
        button(
          on_click=emit(ShowAdmin),
          attrs=@html.Attrs::build().data_set("name", "admin-button"),
          "进入管理面板",
        ),
        button(
          on_click=emit(Logout),
          attrs=@html.Attrs::build().data_set("name", "logout-button"),
          "退出",
        ),
      ])
    } else {
      div(class="auth-bar", [
        a(
          class="button",
          href="/sys/login",
          attrs=@html.Attrs::build().data_set("name", "login-link"),
          "登录",
        ),
      ])
    }
    let admin_panel = div(class="admin-panel", [
      div(class="admin-header", [
        h2("后台管理"),
        button(
          on_click=emit(HideAdmin),
          attrs=@html.Attrs::build().data_set("name", "admin-back-button"),
          "返回文档站",
        ),
      ]),
      section(class="admin-section", [
        h3("用户列表"),
        ul(model.users.map(fn(u) { li(u) })),
      ]),
      section(class="admin-section", [
        h3("站点设置"),
        label(for_="site-title", "产品名"),
        div(class="field", [
          input(
            id="site-title",
            value=model.site_title_input,
            on_input=text => emit(SetSiteTitle(text)),
            attrs=@html.Attrs::build().data_set("name", "site-title-input"),
          ),
          button(
            on_click=emit(SaveSite),
            attrs=@html.Attrs::build().data_set("name", "save-site-button"),
            "保存站点设置",
          ),
        ]),
      ]),
      section(class="admin-section", [
        h3("API 密钥"),
        ul(model.keys.map(fn(k) { li(k) })),
        h4("创建密钥"),
        label(for_="key-name", "名称"),
        div(class="field", [
          input(
            id="key-name",
            value=model.key_name,
            on_input=text => emit(SetKeyName(text)),
            attrs=@html.Attrs::build().data_set("name", "key-name-input"),
          ),
        ]),
        label(for_="key-scopes", "权限"),
        div(class="field", [
          select(
            id="key-scopes",
            on_change=v => emit(SetKeyScopes(v)),
            attrs=@html.Attrs::build().data_set("name", "key-scopes-select"),
            [
              option(
                value="read",
                selected=model.key_scopes == "read",
                "只读",
              ),
              option(
                value="read,write",
                selected=model.key_scopes == "read,write",
                "读写",
              ),
            ],
          ),
        ]),
        label(for_="key-read-prefix", "可读前缀"),
        div(class="field", [
          input(
            id="key-read-prefix",
            value=model.key_read_prefix,
            on_input=text => emit(SetKeyReadPrefix(text)),
            attrs=@html.Attrs::build().data_set("name", "key-read-prefix-input"),
          ),
        ]),
        label(for_="key-write-prefix", "可写前缀"),
        div(class="field", [
          input(
            id="key-write-prefix",
            value=model.key_write_prefix,
            on_input=text => emit(SetKeyWritePrefix(text)),
            attrs=@html.Attrs::build().data_set(
              "name", "key-write-prefix-input",
            ),
          ),
        ]),
        button(
          on_click=emit(CreateKey),
          attrs=@html.Attrs::build().data_set("name", "create-key-button"),
          "创建密钥",
        ),
      ]),
      section(class="admin-section", [
        h3("分类"),
        ul(model.categories.map(fn(c) { li(c) })),
        p(
          "在文档 front matter 的 category 字段填入分类 slug 即可归入。",
        ),
      ]),
    ])
    let editor = if model.editing {
      div(class="editor", [
        textarea(
          rows=20,
          placeholder="Markdown 正文",
          value=model.content,
          on_input=text => emit(SetContent(text)),
          attrs=@html.Attrs::build().data_set("name", "markdown-editor"),
          @html.nothing,
        ),
        div(class="editor-actions", [
          button(
            on_click=emit(Save),
            attrs=@html.Attrs::build().data_set("name", "save-button"),
            "保存",
          ),
          button(
            on_click=emit(Delete),
            attrs=@html.Attrs::build().data_set("name", "delete-button"),
            "删除",
          ),
        ]),
      ])
    } else {
      div(class="readonly", [
        div(class="meta-bar", [
          if model.active_category.is_empty() {
            @html.nothing
          } else {
            span(class="badge", "分类：" + model.active_category)
          },
          if model.active_status.is_empty() || model.active_status == "public" {
            @html.nothing
          } else {
            span(class="badge", "状态：" + model.active_status)
          },
        ]),
        div(
          attrs=@html.Attrs::build()
            .data_set("name", "document-content")
            .inner_html(model.active_html),
          @html.nothing,
        ),
        button(
          on_click=emit(Edit),
          attrs=@html.Attrs::build().data_set("name", "edit-button"),
          "编辑",
        ),
      ])
    }
    let active_title = if model.active_slug.is_empty() {
      "阅读文档"
    } else if model.active_title.is_empty() {
      model.active_slug
    } else {
      model.active_title
    }
    let workspace_view = div(class="workspace", [
      div(class="sidebar", [
        div(class="sidebar-brand", [h2(model.title), p("Wiki")]),
        details(open=true, class="sidebar-group", [
          summary("导航"),
          ul([
            li([a(href="/", "首页")]),
            li([a(href="/feed", "最近更新")]),
            li([a(href="/llms.txt", "LLM 文档索引")]),
          ]),
        ]),
        details(open=true, class="sidebar-group", [
          summary("文档"),
          p(model.slugs.length().to_string() + " 篇文档"),
          div(
            attrs=@html.Attrs::build().data_set("name", "document-list"),
            doc_buttons,
          ),
        ]),
        details(class="sidebar-group", [
          summary("工具"),
          ul([
            li([a(href="/api/v1/docs", "文档 API")]),
            li([a(href="/docs/API.md", "API 说明")]),
            li([a(href="/feed", "RSS 订阅")]),
          ]),
        ]),
        details(class="sidebar-group", [
          summary("其他页面"),
          ul([li([a(href="/sys/login", "登录")])]),
        ]),
      ]),
      div(class="editor-panel", [
        div(class="wiki-tabs", [
          span(class="wiki-tab active", "阅读"),
          button(
            class="wiki-tab",
            on_click=emit(Edit),
            attrs=@html.Attrs::build().data_set("name", "edit-tab"),
            "编辑",
          ),
          a(class="wiki-tab", href="#history", "查看历史"),
        ]),
        h2(active_title),
        editor,
      ]),
    ])
    let content_area = if model.admin_view {
      admin_panel
    } else {
      workspace_view
    }
    html([
      head([
        @html.node(
          "script",
          @html.Attrs::build().src("/theme.js"),
          @html.nothing,
        ),
        link(rel="stylesheet", href="/site.css"),
        title(model.title),
      ]),
      body <| [
        div(class="reading-shell") <| [
          div(class="topbar", [
            h1(model.title + " 文档站"),
            div(class="controls", [
              button(
                class="button",
                on_click=emit(LoadDocs),
                attrs=@html.Attrs::build().data_set(
                  "name", "load-documents-button",
                ),
                "加载文档",
              ),
              input(
                input_type=@html.InputType::Search,
                placeholder="搜索文档",
                value=model.query,
                on_input=text => emit(SetQuery(text)),
                attrs=@html.Attrs::build().data_set("name", "search-input"),
              ),
              theme_switch,
              auth_ui,
            ]),
          ]),
          p(model.status),
          content_area,
        ],
      ],
    ])
  })
}
