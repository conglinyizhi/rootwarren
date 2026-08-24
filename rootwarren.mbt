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
    None => "rootwarren"
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
/// `base_slug` 是当前文档的 slug（用于解析相对路径目录）。
/// 规则：不以 `/`、`http(s):`、`#`、`mailto:` 开头的目标视为站点内相对链接，
/// 基于 `base_slug` 的目录解析成绝对 `/d/{slug}`，并去掉 `.md` 后缀。
pub fn rewrite_wiki_links(html : String, base_slug : String) -> String {
  rewrite_hrefs(html, base_slug)
}

///|
/// 从已重写的渲染 HTML 中提取所有指向站点文档的 slug（去重），用于链接台账。
pub fn extract_link_slugs(html : String) -> Array[String] {
  let seen : Map[String, Bool] = Map([])
  let acc : Array[String] = []
  let mut rest = html
  while rest.length() > 0 {
    match rest.find("/d/") {
      None => break
      Some(i) => {
        let after = rest[i + 3:].to_owned()
        let slug = take_slug(after)
        if !slug.is_empty() && !seen.contains(slug) {
          seen[slug] = true
          ignore(acc.push(slug))
        }
        rest = after
      }
    }
  }
  acc
}

///|
/// 从 `/d/` 之后的字符串提取一个 slug 片段。
fn take_slug(s : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < s.length() {
    match s.get_char(i) {
      Some(c) =>
        if (c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') ||
          c == '/' ||
          c == '-' ||
          c == '_' ||
          c == '.' {
          sb.write_char(c)
          i += 1
        } else {
          break
        }
      None => break
    }
  }
  sb.to_string()
}

///|
/// 把站点内路径（可能含 `./`/`../`/`.md`）归一化为不带前导斜杠的 slug。
fn resolve_abs(path : String) -> String {
  let p = strip_md(path)
  let parts : Array[String] = []
  for seg in p.split("/") {
    let s = seg.trim().to_owned()
    if s.is_empty() || s == "." {
      continue
    } else if s == ".." {
      if parts.length() > 0 {
        ignore(parts.pop())
      }
    } else {
      parts.push(s)
    }
  }
  parts.join("/")
}

///|
/// 去掉末尾 `.md` 后缀。
fn strip_md(p : String) -> String {
  if p.has_suffix(".md") {
    p[:p.length() - 3].to_owned()
  } else {
    p
  }
}

///|
/// 扫描已渲染 HTML 的所有 `href="..."`，把相对链接重写为 `/d/{slug}`。
fn rewrite_hrefs(html : String, base_slug : String) -> String {
  recur_rewrite_hrefs(html, base_slug, "")
}

///|
/// 递归扫描剩余字符串，累积重写结果。
fn recur_rewrite_hrefs(
  rest : String,
  base_slug : String,
  out : String,
) -> String {
  let dir = base_dir_of(base_slug)
  match rest.find("href=\"") {
    None => out + rest
    Some(i) => {
      let before = rest[:i + 6].to_owned()
      let after = rest[i + 6:]
      match after.find("\"") {
        None => out + before + after.to_owned()
        Some(j) => {
          let val = after[:j].to_owned()
          let rewritten = rewrite_one_href(val, dir)
          recur_rewrite_hrefs(
            after[j + 1:].to_owned(),
            base_slug,
            out + before + rewritten + "\"",
          )
        }
      }
    }
  }
}

///|
/// 根据 dir 目录重写一条 href：站点内相对链接 → `/d/{slug}`，否则保持。
fn rewrite_one_href(val : String, dir : String) -> String {
  if val.is_empty() {
    return val
  }
  if val.has_prefix("/") ||
    val.has_prefix("http://") ||
    val.has_prefix("https://") ||
    val.has_prefix("#") ||
    val.has_prefix("mailto:") ||
    val.has_prefix("data:") {
    return val
  }
  // 相对链接：基于当前文档目录 dir 解析，再归一化到站点内 slug。
  let base = if dir.is_empty() { "" } else { dir + "/" }
  let rel = strip_md(val)
  let full = base + rel
  let slug = resolve_abs(full)
  if slug.is_empty() {
    val
  } else {
    "/d/" + slug
  }
}

///|
/// 取 base_slug 去掉最后一段后的目录前缀（如 `guide/getting-started` → `guide`）。
fn base_dir_of(base_slug : String) -> String {
  let parts = base_slug.split("/")
  if parts.length() <= 1 {
    ""
  } else {
    parts[0:parts.length() - 1].join("/")
  }
}

///|
/// 渲染一篇 Markdown 文档为可展示的 HTML 段落（不含页面骨架）。
/// `slug` 用于把正文里的相对链接解析成 `/d/{slug}`。
pub fn render_doc_html(raw : String, slug : String) -> String {
  let meta = document_meta(raw)
  let html = @cmark_html.render(meta.body, safe=true) catch { _ => "" }
  rewrite_wiki_links(html, slug)
}

///|
pub fn config_site_title(value : String?) -> String {
  match value {
    Some(v) if !v.is_empty() => v
    _ => "rootwarren"
  }
}
