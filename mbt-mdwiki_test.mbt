// Blackbox tests for the root library (document parsing + wikilink rewriting).
// Run with `moon test`. Uses the package's public API via `@mbt-mdwiki`.

///|
/// 解析带 front matter 的 Markdown，提取 title/tags/status/category。
test "document_meta parses front matter" {
  let raw = "---\ntitle: Hello\ntags: a, b\nstatus: hidden\ncategory: guide\n---\n\nBody text\n"
  let meta = @mbt-mdwiki.document_meta(raw)
  assert_eq(meta.title, "Hello")
  assert_eq(meta.tags, "a, b")
  assert_eq(meta.status, "hidden")
  assert_eq(meta.category, "guide")
  assert_eq(meta.body, "\nBody text\n")
}

///|
/// 无 front matter 时回退：用首个 H1 作标题，status 为 public。
test "document_meta falls back without front matter" {
  let raw = "# My Page\n\ncontent\n"
  let meta = @mbt-mdwiki.document_meta(raw)
  assert_eq(meta.title, "My Page")
  assert_eq(meta.status, "public")
  assert_eq(meta.category, "")
}

///|
/// 相对链接重写：相对路径解析为带 `/d/` 前缀的 slug。
test "rewrite_wiki_links resolves relative links" {
  let html = "<a href=\"getting-started\">x</a>"
  let out = @mbt-mdwiki.rewrite_wiki_links(html, "index")
  assert_eq(out, "<a href=\"/d/getting-started\">x</a>")
}

///|
/// 绝对/外部/锚点链接不改写。
test "rewrite_wiki_links keeps absolute and external links" {
  let html = "<a href=\"/api/v1/docs\">api</a><a href=\"https://x.com\">ext</a><a href=\"#top\">a</a>"
  let out = @mbt-mdwiki.rewrite_wiki_links(html, "index")
  assert_eq(out, "<a href=\"/api/v1/docs\">api</a><a href=\"https://x.com\">ext</a><a href=\"#top\">a</a>")
}

///|
/// config_site_title：空值回退默认，非空用指定值。
test "config_site_title default and override" {
  assert_eq(@mbt-mdwiki.config_site_title(None), "mbt-mdwiki")
  assert_eq(@mbt-mdwiki.config_site_title(Some("Final Wiki")), "Final Wiki")
  assert_eq(@mbt-mdwiki.config_site_title(Some("")), "mbt-mdwiki")
}
