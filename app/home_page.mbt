// 独立首页组件：接收服务端注入的数据（文档列表 + index 正文）。
// 返回完整 <html> 骨架（SSR 需完整结构才可渲染），SSR 与前端 hydrate 共用。

///|
pub struct HomeInput {
  title : String
  doc_html : String
  doc_list : Array[String]
} derive(Eq)

///|
/// HomeInput 构造工厂（跨包构造 struct 字面量受限，用此函数）。
pub fn home_input(
  title : String,
  doc_html : String,
  doc_list : Array[String],
) -> HomeInput {
  { title, doc_html, doc_list }
}

///|
pub fn home_page(input~ : HomeInput) -> @rabbita.Val[@html.Html] {
  // 纯展示：用 create_pure_state 包一个常量状态，view 渲染出完整 Html
  let (state, _set) = @rabbita.create_pure_state(
    input,
    update=fn(model, _msg) { model },
  )
  state.view(model => {
    let list = @html.ul(
      model.doc_list.map(fn(s) {
        @html.li([@html.a(href="/d/" + s, s)])
      }),
    )
    let content = @html.div(
      attrs=@html.Attrs::build().class("home-page"),
      [
        @html.h1(model.title),
        @html.div(
          attrs=@html.Attrs::build().inner_html(model.doc_html),
          @html.nothing,
        ),
        @html.h2("文档列表"),
        list,
      ],
    )
    let shell = @html.div(class="reading-shell", [content])
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
      @html.body([shell]),
    ])
  })
}
