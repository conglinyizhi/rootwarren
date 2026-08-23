// 共享的 Markdown 文档渲染工具。
// 纯函数，不依赖 HTTP/存储层；供后端 cmd/server 复用，
// 保障渲染安全边界不被重写。

///|
pub struct DocumentMeta {
  body : String
  title : String
  tags : String
  status : String
  category : String
}

///|
/// 解析 Markdown front matter（`title` / `tags` / `status` / `category`），返回结构体。
pub fn document_meta(raw : String) -> DocumentMeta {
  let fallback_title = match raw.find("# ") {
    Some(i) => {
      let line = raw[i + 2:]
      match line.find("\n") {
        Some(end) => line[:end].to_owned()
        None => line.to_owned()
      }
    }
    None => "mbt-mdwiki"
  }
  if !raw.has_prefix("---\n") {
    return {
      body: raw,
      title: fallback_title,
      tags: "",
      status: "public",
      category: "",
    }
  }
  let end = match raw.find("\n---\n") {
    Some(i) => i
    None =>
      return {
        body: raw,
        title: fallback_title,
        tags: "",
        status: "public",
        category: "",
      }
  }
  let header = raw[4:end]
  let body = raw[end + 5:].to_owned()
  let mut title = fallback_title
  let mut tags = ""
  let mut status = "public"
  let mut category = ""
  for line in header.split("\n") {
    let line = line.to_owned()
    if line.has_prefix("title:") {
      title = line[6:].trim().to_owned()
    } else if line.has_prefix("tags:") {
      tags = line[5:].trim().to_owned()
    } else if line.has_prefix("status:") {
      status = line[7:].trim().to_owned()
    } else if line.has_prefix("category:") {
      category = line[9:].trim().to_owned()
    }
  }
  { body, title, tags, status, category }
}

///|
/// 将已渲染的 Markdown HTML 中的相对 Wiki 链接重写为 `/d/{slug}` 形式。
pub fn rewrite_wiki_links(html : String) -> String {
  html
  .replace_all(old="href=\"guide/", new="href=\"/d/guide/")
  .replace_all(old="href=\"../index\"", new="href=\"/d/index\"")
  .replace_all(
    old="href=\"client-design\"",
    new="href=\"/d/guide/client-design\"",
  )
  .replace_all(
    old="href=\"access-control\"",
    new="href=\"/d/guide/access-control\"",
  )
}

///|
/// 渲染一篇 Markdown 文档为可展示的 HTML 段落（不含页面骨架）。
pub fn render_doc_html(raw : String) -> String {
  let meta = document_meta(raw)
  let html = @cmark_html.render(meta.body, safe=true) catch { _ => "" }
  rewrite_wiki_links(html)
}

///|
pub fn config_site_title(value : String?) -> String {
  match value {
    Some(v) if !v.is_empty() => v
    _ => "mbt-mdwiki"
  }
}
