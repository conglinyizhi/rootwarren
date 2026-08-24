// 站点级路由：/health、/llms.txt、/feed、/api/v1/config 与站点配置/订阅辅助。

///|
async fn site_product_name(meta : @lib.JsonMeta) -> String {
  match meta.get_config("site.title") {
    Some(v) if !v.is_empty() => v
    _ => "rootwarren"
  }
}

///|
async fn site_show_tree(meta : @lib.JsonMeta) -> Bool {
  match meta.get_config("site.show_tree") {
    Some(v) if v == "false" => false
    _ => true
  }
}

///|
async fn site_is_public(meta : @lib.JsonMeta) -> Bool {
  match meta.get_config("site.public") {
    Some(v) if v == "false" => false
    _ => true
  }
}

///|
async fn site_llms_mode(meta : @lib.JsonMeta) -> String {
  match meta.get_config("site.llms_mode") {
    Some(value) => value
    None => "public"
  }
}

///|
async fn site_llms_prefixes(meta : @lib.JsonMeta) -> String {
  match meta.get_config("site.llms_prefixes") {
    Some(value) => value
    None => ""
  }
}

///|
/// 生成 llms.txt 内容（Markdown 索引）。prefixes 为空时全部收录。
async fn serve_llms(storage : @lib.LocalStorage, prefixes : String) -> String {
  let output = StringBuilder()
  output.write_string("# rootwarren\n\n")
  output.write_string("这是一个由 MoonBit 驱动的 Markdown Wiki。\n\n")
  for slug in storage.list() {
    let allowed = prefixes.is_empty() ||
      prefixes
      .split(",")
      .any(fn(prefix) {
        let prefix = prefix.trim().to_owned()
        slug == prefix || slug.has_prefix(prefix + "/")
      })
    if !allowed {
      continue
    }
    match storage.read(slug) {
      Some(raw) => {
        let meta = @lib.document_meta(raw)
        output.write_string("- [")
        output.write_string(meta.title)
        output.write_string("](/d/")
        output.write_string(slug)
        output.write_string(".md)")
        if !meta.tags.is_empty() {
          output.write_string(" #")
          output.write_string(
            meta.tags.replace(old=", ", new=" #").replace(old=",", new=" "),
          )
        }
        output.write_string("\n")
      }
      None => ()
    }
  }
  output.to_string()
}

///|
/// 生成 RSS 2.0 订阅（遍历公开文档的 title/link/description）。
async fn serve_rss(storage : @lib.LocalStorage, meta : @lib.JsonMeta) -> String {
  let product_name = site_product_name(meta)
  let out = StringBuilder()
  out.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  out.write_string("<rss version=\"2.0\"><channel>\n")
  out.write_string("<title>" + escape_xml(product_name) + "</title>\n")
  out.write_string("<link>http://127.0.0.1/</link>\n")
  out.write_string(
    "<description>" + escape_xml(product_name) + " 文档订阅</description>\n",
  )
  for slug in storage.list() {
    match storage.read(slug) {
      Some(raw) => {
        let dm = @lib.document_meta(raw)
        let title = if dm.title.is_empty() { slug } else { dm.title }
        let desc = if dm.tags.is_empty() { "" } else { "标签：" + dm.tags }
        out.write_string("<item>\n")
        out.write_string("<title>" + escape_xml(title) + "</title>\n")
        out.write_string(
          "<link>http://127.0.0.1/d/" + escape_xml(slug) + "</link>\n",
        )
        out.write_string(
          "<description>" + escape_xml(desc) + "</description>\n",
        )
        out.write_string("</item>\n")
      }
      None => ()
    }
  }
  out.write_string("</channel></rss>\n")
  out.to_string()
}

///|
fn escape_xml(s : String) -> String {
  s
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
}

///|
/// 注册站点级路由：/health、/llms.txt、/feed、/api/v1/config。
fn register_site_routes(
  ctx : @moonback.ModuleContext,
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
) -> Unit raise {
  ctx.get("/health", (_req, res) => res.send_json({ "status": "ok" }))
  ctx.get("/llms.txt", (_req, res) => {
    let mode = site_llms_mode(meta)
    if mode == "public" {
      res.send_text(serve_llms(storage, ""))
    } else if mode == "partial" {
      res.send_text(serve_llms(storage, site_llms_prefixes(meta)))
    } else {
      res.send_void(status=404)
    }
  })
  ctx.get("/feed", (_req, res) => {
    let w = res.respond(headers=[
      ("Content-Type", "application/rss+xml; charset=utf-8"),
    ])
    w.write(serve_rss(storage, meta))
  })
  ctx.get("/api/v1/config", (_req, res) => {
    let product_name = match meta.get_config("site.title") {
      Some(v) if !v.is_empty() => v
      _ => "rootwarren"
    }
    res.send_json({ "title": Json::string(product_name) })
  })
}
