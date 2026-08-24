// 文档相关路由：/d/{slug}、/posts/{slug}、/category/{slug}、/api/v1/docs*、/api/v1/backlinks 与渲染辅助。

///|
/// 服务端渲染一篇文章为完整 HTML 页面（复用根库渲染工具）。
async fn render_doc_page(
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  slug : String,
  show_edit : Bool,
) -> String {
  match storage.read(slug) {
    Some(raw) => {
      let doc = @lib.document_meta(raw)
      let html = @lib.render_doc_html(raw, slug)
      let product_name = site_product_name(meta)
      let tags = if doc.tags.is_empty() {
        ""
      } else {
        let chips = doc.tags
          .replace_all(old=", ", new=",")
          .split(",")
          .map(fn(tag) {
            "<span class=\"tag\">" + tag.trim().to_owned() + "</span>"
          })
          .join("")
        "<div class=\"tags\"><small>标签</small>" + chips + "</div>"
      }
      let tree = if site_show_tree(meta) {
        let items = storage
          .list()
          .map(fn(item) {
            "<li><a href=\"/d/" + item + "\">" + item + "</a></li>"
          })
          .join("")
        "<nav class=\"doc-tree\"><strong>文档目录</strong><ul>" +
        items +
        "</ul></nav>"
      } else {
        ""
      }
      let breadcrumb = build_breadcrumb(product_name, slug, doc.title)
      let sources = meta.backlinks(slug)
      let backlinks_html = if sources.is_empty() {
        ""
      } else {
        let items = sources
          .map(fn(s) { "<li><a href=\"/d/" + s + "\">" + s + "</a></li>" })
          .join("")
        "<div class=\"backlinks\"><strong>链入页面</strong><ul>" +
        items +
        "</ul></div>"
      }
      "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" +
      doc.title +
      " - " +
      product_name +
      "</title><script src=\"/theme.js\"></script><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"reading-shell\"><div class=\"topbar\"><a href=\"/\">" +
      product_name +
      "</a>" +
      (if show_edit {
        "<span class=\"account\"><a href=\"/d/" + slug + "?edit\">编辑</a></span>"
      } else {
        ""
      }) +
      "</div><div class=\"breadcrumbs\">" +
      breadcrumb +
      "</div>" +
      tree +
      "<article>" +
      html +
      tags +
      backlinks_html +
      "</article></main></body></html>"
    }
    None =>
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>文档不存在</title></head><body><p>文档不存在</p></body></html>"
  }
}

///|
/// 渲染编辑页（/d/{slug}?edit=1）：textarea 填 Markdown 原文 + 保存/取消，内联 JS 保存到 API。
async fn render_edit_page(
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  slug : String,
) -> String {
  let product_name = site_product_name(meta)
  let raw = match storage.read(slug) {
    Some(r) => r
    None => ""
  }
  let dm = @lib.document_meta(raw)
  let body = dm.body
  let escaped = body
    .replace_all(old="&", new="&amp;")
    .replace_all(old="<", new="&lt;")
    .replace_all(old=">", new="&gt;")
    .replace_all(old="\"", new="&quot;")
  let read_url = "/d/" + slug + "?edit=0"
  "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>编辑 " +
  dm.title +
  " - " +
  product_name +
  "</title><script src=\"/theme.js\"></script><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"reading-shell\"><div class=\"topbar\"><a href=\"/\">" +
  product_name +
  "</a><span class=\"account\"><a href=\"/d/" + slug + "\">返回阅读</a></span></div><h1>编辑：" +
  dm.title +
  "</h1><textarea id=\"editor\" rows=\"24\" style=\"width:100%;font-family:monospace\">" +
  escaped +
  "</textarea><div class=\"editor-actions\"><button id=\"save\">保存</button><button id=\"cancel\">取消</button><span id=\"msg\"></span></div></main><script>(function(){var e=document.getElementById('editor'),m=document.getElementById('msg');document.getElementById('save').onclick=function(){fetch('/api/v1/docs/" +
  slug +
  "',{method:'PUT',headers:{'Content-Type':'text/markdown'},body:e.value}).then(function(r){if(r.ok){m.textContent='已保存，跳转中…';location.href='/d/" +
  slug +
  "'}else{m.textContent='保存失败'}})};document.getElementById('cancel').onclick=function(){location.href='/d/" +
  slug +
  "'}})()</script></body></html>"
}

///|
/// 确保字符串以单个换行结尾（供 LLM/Agent 读取 Markdown 原文时整洁）。
fn ensure_trailing_newline(s : String) -> String {
  if s.is_empty() || s.has_suffix("\n") {
    s
  } else {
    s + "\n"
  }
}

///|
struct CatInfo {
  slug : String
  name : String
  count : Int
}

///|
/// 聚合所有文档的分类，返回分类 + 文档计数。
async fn category_list(
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
) -> Array[CatInfo] {
  let counts : Map[String, Int] = Map([])
  for slug in storage.list() {
    match storage.read(slug) {
      Some(raw) => {
        let cat = @lib.document_meta(raw).category
        if !cat.is_empty() {
          counts[cat] = counts.get(cat).unwrap_or(0) + 1
        }
      }
      None => ()
    }
  }
  // 优先用已定义分类的 name；未定义分类用 slug 本身
  let defined = meta.list_categories()
  let result : Array[CatInfo] = []
  for slug, count in counts {
    let name = match
      defined.fold(init="", fn(acc, c) {
        if c.slug == slug {
          c.name
        } else {
          acc
        }
      }) {
      "" => slug
      n => n
    }
    result.push({ slug, name, count, })
  }
  result
}

///|
/// 渲染分类页：列出该分类下的全部文档。
async fn render_category_page(
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  slug : String,
) -> String {
  let product_name = site_product_name(meta)
  let items : Array[String] = []
  for doc_slug in storage.list() {
    match storage.read(doc_slug) {
      Some(raw) => {
        let dm = @lib.document_meta(raw)
        if dm.category == slug && dm.status != "hidden" {
          items.push(
            "<li><a href=\"/d/" + doc_slug + "\">" + dm.title + "</a></li>",
          )
        }
      }
      None => ()
    }
  }
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>" +
  slug +
  " - " +
  product_name +
  "</title><script src=\"/theme.js\"></script><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"reading-shell\"><div class=\"topbar\"><a href=\"/\">" +
  product_name +
  "</a></div><h1>分类：" +
  slug +
  "</h1><ul>" +
  items.join("") +
  "</ul></main></body></html>"
}

///|
fn build_breadcrumb(
  product_name : String,
  slug : String,
  title : String,
) -> String {
  if slug == "index" {
    "<a href=\"/\">" +
    product_name +
    "</a><span>/</span><strong>首页</strong>"
  } else {
    let parts = slug.split("/").to_array()
    let mut links = "<a href=\"/\">" + product_name + "</a><span>/</span>"
    for i in 0..<parts.length() {
      let part = parts[i].to_owned()
      let href = "/d/" + parts[:i + 1].join("/")
      links = links +
        (if i == parts.length() - 1 {
          "<strong>" + title + "</strong>"
        } else {
          "<a href=\"" + href + "\">" + part + "</a>"
        })
      if i < parts.length() - 1 {
        links = links + "<span>/</span>"
      }
    }
    links
  }
}

///|
/// 注册文档路由：/d/、/posts/、/category/、/api/v1/docs*、/api/v1/backlinks。
fn register_docs_routes(
  ctx : @moonback.ModuleContext,
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  auth : AuthState,
) -> Unit raise {
  ctx.get("/d/*slug", (req, res) => {
    // 公私有控制：site.public=false 且未登录时匿名读 403
    if !site_is_public(meta) && auth.authenticate(req) is None {
      res.send_text("site is private; login required", status=403)
      return
    }
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    // 以 `.md` 结尾的 URL：返回该文档的 Markdown 原文（供 LLM/Agent 直接读取，避免 HTML 干扰）
    if slug.has_suffix(".md") {
      let raw_slug = slug[:slug.length() - 3].to_owned()
      match storage.read(raw_slug) {
        Some(raw) => {
          let dm = @lib.document_meta(raw)
          let body = dm.body
          let w = res.respond(status=200, headers=[
            ("Content-Type", "text/markdown; charset=utf-8"),
          ])
          w.write(ensure_trailing_newline(body))
        }
        None => res.send_void(status=404)
      }
      return
    }
    // 编辑意图：URL 带 ?edit 且用户有编辑权限 → 渲染可编辑文本框
    let edit_intent = req.query().has("edit")
    if edit_intent && auth.can_edit(req) {
      let page = render_edit_page(storage, meta, slug)
      res.send_html(@moonback.Html::raw(page))
      return
    }
    let show_edit = auth.can_edit(req)
    let page = render_doc_page(storage, meta, slug, show_edit)
    res.send_html(@moonback.Html::raw(page))
  })
  // Typecho 式文章固定链接别名（/posts/{slug}），与 /d/{slug} 渲染一致
  ctx.get("/posts/*slug", (req, res) => {
    if !site_is_public(meta) && auth.authenticate(req) is None {
      res.send_text("site is private; login required", status=403)
      return
    }
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    let show_edit = auth.can_edit(req)
    let page = render_doc_page(storage, meta, slug, show_edit)
    res.send_html(@moonback.Html::raw(page))
  })

  ctx.get("/api/v1/categories", (_req, res) => {
    let cats = category_list(storage, meta)
    let items = cats.map(fn(c) {
      Json::object({
        "slug": Json::string(c.slug),
        "name": Json::string(c.name),
        "count": Json::number(c.count.to_double()),
      })
    })
    res.send_json({ "categories": Json::array(items) })
  })
  ctx.get("/category/*slug", (req, res) => {
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    let page = render_category_page(storage, meta, slug)
    res.send_html(@moonback.Html::raw(page))
  })

  ctx.get("/api/v1/docs", (req, res) => {
    let perm = auth.docs_auth(meta, req)
    if !can_read(perm.scopes) {
      res.send_json(
        { "error": Json::string("read permission required") },
        status=403,
      )
      return
    }
    let slugs = storage
      .list()
      .filter(fn(slug) { allowed_read_prefix(perm.read_prefix, slug) })
    let items = slugs.map(fn(slug) { Json::string(slug) })
    res.send_json({ "docs": Json::array(items) })
  })
  ctx.get("/api/v1/docs/*slug", (req, res) => {
    let perm = auth.docs_auth(meta, req)
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    if !can_read(perm.scopes) {
      res.send_json(
        { "error": Json::string("read permission required") },
        status=403,
      )
      return
    }
    if !allowed_read_prefix(perm.read_prefix, slug) {
      res.send_json(
        { "error": Json::string("document outside readable range") },
        status=403,
      )
      return
    }
    match storage.read(slug) {
      Some(raw) => {
        let html = @lib.render_doc_html(raw, slug)
        let dm = @lib.document_meta(raw)
        res.send_json({
          "slug": Json::string(slug),
          "html": Json::string(html),
          "content": Json::string(raw),
          "category": Json::string(dm.category),
          "status": Json::string(dm.status),
        })
      }
      None => res.send_json({ "error": Json::string("not found") }, status=404)
    }
  })
  ctx.get("/api/v1/backlinks/*slug", (req, res) => {
    let perm = auth.docs_auth(meta, req)
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    if !can_read(perm.scopes) {
      res.send_json(
        { "error": Json::string("read permission required") },
        status=403,
      )
      return
    }
    let sources = meta.backlinks(slug)
    res.send_json({
      "slug": Json::string(slug),
      "backlinks": Json::array(sources.map(Json::string)),
    })
  })

  ctx.add_route(@http.RequestMethod::Put, "/api/v1/docs/*slug", (req, res) => {
    let perm = auth.docs_auth(meta, req)
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    if !@lib.valid_slug(slug) {
      res.send_text("invalid slug", status=400)
      return
    }
    if !can_write(perm.scopes) || !allowed_write_prefix(perm.write_prefix, slug) {
      res.send_json(
        { "error": Json::string("write permission required") },
        status=403,
      )
      return
    }
    let content = req.body.text()
    let success = try {
      storage.write(slug, content)
      true
    } catch {
      _ => false
    }
    if success {
      // 更新文档链接台账：解析该文档引用的目标并记录。
      let html = @lib.render_doc_html(content, slug)
      let targets = @lib.extract_link_slugs(html)
      meta.record_links(slug, targets)
      res.send_json({ "ok": Json::boolean(true) })
    } else {
      res.send_text("invalid slug", status=400)
    }
  })
  ctx.add_route(@http.RequestMethod::Delete, "/api/v1/docs/*slug", (req, res) => {
    let perm = auth.docs_auth(meta, req)
    let slug = match req.params.get("slug") {
      Some(s) => s.to_owned()
      None => {
        res.send_text("missing slug", status=400)
        return
      }
    }
    if !@lib.valid_slug(slug) {
      res.send_text("invalid slug", status=400)
      return
    }
    if !can_write(perm.scopes) || !allowed_write_prefix(perm.write_prefix, slug) {
      res.send_json(
        { "error": Json::string("write permission required") },
        status=403,
      )
      return
    }
    storage.delete(slug)
    meta.remove_source_links(slug)
    res.send_json({ "ok": Json::boolean(true) })
  })
}
