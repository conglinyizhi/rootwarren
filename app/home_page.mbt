// 独立首页组件：接收服务端注入的数据（文档列表 + index 正文）。
// 复现原 SPA 首页的双栏布局(左侧文档树侧栏 + 右侧正文)，SSR 与前端 hydrate 共用。

///|
pub struct HomeInput {
  title : String
  doc_html : String
  doc_list : Array[String]
  authed : Bool
} derive(Eq)

///|
/// HomeInput 构造工厂（跨包构造 struct 字面量受限，用此函数）。
pub fn home_input(
  title : String,
  doc_html : String,
  doc_list : Array[String],
  authed : Bool,
) -> HomeInput {
  { title, doc_html, doc_list, authed }
}

///|
pub fn home_page(input~ : HomeInput) -> @rabbita.Val[@html.Html] {
  // 纯展示：用 create_pure_state 包一个常量状态，view 渲染出完整 Html
  let (state, _set) = @rabbita.create_pure_state(
    input,
    update=fn(model, _msg) { model },
  )
  state.view(model => {
    // 顶部动作：登录/管理
    let auth_links = if model.authed {
      @html.div(class="account", [
        @html.a(href="/sys/admin", "进入管理面板"),
        @html.a(href="/sys/login", "退出"),
      ])
    } else {
      @html.div(class="account", [
        @html.a(href="/sys/login", "登录"),
      ])
    }
    // 侧栏：折叠分组（导航 / 文档 / 工具）
    let doc_links = model.doc_list.map(fn(s) {
      @html.li([@html.a(href="/d/" + s, s)])
    })
    let sidebar = @html.div(class="sidebar", [
      @html.details(open=true, class="sidebar-group", [
        @html.summary("导航"),
        @html.ul([
          @html.li([@html.a(href="/", "首页")]),
          @html.li([@html.a(href="/llms.txt", "LLM 文档索引")]),
        ]),
      ]),
      @html.details(open=true, class="sidebar-group", [
        @html.summary("文档"),
        @html.p(model.doc_list.length().to_string() + " 篇文档"),
        @html.ul(doc_links),
      ]),
      @html.details(class="sidebar-group", [
        @html.summary("工具"),
        @html.ul([
          @html.li([@html.a(href="/api/v1/docs", "文档 API")]),
          @html.li([@html.a(href="/d/api/index", "API 说明")]),
          @html.li([@html.a(href="/feed", "RSS 订阅")]),
        ]),
      ]),
      @html.details(class="sidebar-group", [
        @html.summary("其他页面"),
        @html.ul([
          @html.li([@html.a(href="/sys/login", "登录")]),
        ]),
      ]),
    ])
    // 右侧：正文
    let article = @html.article([
      @html.div(
        attrs=@html.Attrs::build().inner_html(model.doc_html),
        @html.nothing,
      ),
    ])
    let editor_panel = @html.div(class="editor-panel", [
      @html.div(class="wiki-tabs", [
        @html.span(class="wiki-tab active", "阅读"),
      ]),
      article,
    ])
    // 双栏 workspace
    let workspace = @html.div(class="workspace", [sidebar, editor_panel])
    // 页面骨架
    let main = @html.main_(class="reading-shell", [
      @html.div(class="topbar", [
        @html.h1(model.title),
        auth_links,
      ]),
      workspace,
    ])
    @html.html([
      @html.head([
        @html.node(
          "script",
          @html.Attrs::build().src("/theme.js"),
          @html.nothing,
        ),
        @html.link(rel="stylesheet", href="/site.css"),
        @html.title(model.title),
      ]),
      @html.body([main]),
    ])
  })
}
