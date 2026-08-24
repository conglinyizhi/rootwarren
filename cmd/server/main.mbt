///|
#warnings("-alert_experimental")
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let meta = @lib.JsonMeta::open("meta")
  // 先加载 .env（shell 环境变量优先），再读取配置
  let env = @env.get_env_vars()
  load_dotenv(env)
  let port = cli_port(env)
  let admin_user = match meta.get_config("auth.admin_username") {
    Some(v) if !v.is_empty() => v
    _ => "operator"
  }
  let admin_hash = match meta.get_config("auth.admin_key_hash") {
    Some(v) => v
    None =>
      match env.get("ADMIN_TOKEN") {
        Some(v) if !v.is_empty() => @lib.hash_api_key(v)
        _ => ""
      }
  }
  let auth = AuthState::new(admin_user, admin_hash)
  let api = @moonback.Module(ctx => {
    // 静态资源：rabbit page_service 会引用 /styles.css 与 /index.js
    ctx.add_middleware(@static.new(root="public"))
    ctx.get("/health", (_req, res) => res.send_json({ "status": "ok" }))

    // 认证
    ctx.post("/api/auth/login", (req, res) => {
      let body = req.body.text()
      let (username, password) = parse_login(body)
      let result = if auth.admin_login(username, password) is Some(token) {
        Some((token, "admin"))
      } else {
        match meta.verify_user(username, password) {
          Some(user) =>
            match auth.register_user(user) {
              Some(token) => Some((token, "user"))
              None => None
            }
          None => None
        }
      }
      match result {
        Some((token, role)) => {
          let cookie = "mbt_auth=" + token + "; Path=/; HttpOnly; SameSite=Lax"
          res.send_json(
            { "token": Json::string(token), "role": Json::string(role) },
            headers=[("Set-Cookie", cookie)],
          )
        }
        None =>
          res.send_json(
            { "error": Json::string("invalid credentials") },
            status=401,
          )
      }
    })
    ctx.post("/api/auth/logout", (req, res) => {
      auth.logout(req)
      res.send_json({ "ok": Json::boolean(true) })
    })
    ctx.get("/api/auth/me", (req, res) => {
      match auth.authenticate(req) {
        Some(subject) =>
          res.send_json({
            "subject": Json::string(subject),
            "role": Json::string(auth.session_role(req)),
            "can_edit": Json::boolean(auth.can_edit(req)),
          })
        None =>
          res.send_json({ "error": Json::string("unauthorized") }, status=401)
      }
    })

    // 后台管理：仅管理员可访问
    ctx.get("/api/admin/users", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let users = meta.list_users()
      let items = users.map(fn(u) {
        Json::object({
          "id": Json::number(u.id.to_double()),
          "username": Json::string(u.username),
          "role": Json::string(u.role),
          "enabled": Json::boolean(u.enabled),
          "write_prefix": Json::string(u.write_prefix),
        })
      })
      res.send_json({ "users": Json::array(items) })
    })
    ctx.get("/api/admin/site", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let title = match meta.get_config("site.title") {
        Some(v) => v
        None => "mbt-mdwiki"
      }
      let public = match meta.get_config("site.public") {
        Some(v) => v
        None => "true"
      }
      let show_tree = match meta.get_config("site.show_tree") {
        Some(v) => v
        None => "true"
      }
      let llms_mode = match meta.get_config("site.llms_mode") {
        Some(v) => v
        None => "public"
      }
      let llms_prefixes = match meta.get_config("site.llms_prefixes") {
        Some(v) => v
        None => ""
      }
      res.send_json({
        "title": Json::string(title),
        "public": Json::string(public),
        "show_tree": Json::string(show_tree),
        "llms_mode": Json::string(llms_mode),
        "llms_prefixes": Json::string(llms_prefixes),
      })
    })
    ctx.post("/api/admin/site", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let body = req.body.text()
      let cfg = parse_site(body)
      meta.set_config("site.title", cfg.title)
      meta.set_config("site.public", cfg.public)
      meta.set_config("site.show_tree", cfg.show_tree)
      meta.set_config("site.llms_mode", cfg.llms_mode)
      meta.set_config("site.llms_prefixes", cfg.llms_prefixes)
      res.send_json({ "ok": Json::boolean(true) })
    })

    // 用户管理
    ctx.post("/api/admin/users", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let body = req.body.text()
      let json = @json.parse(body) catch {
        _ => {
          res.send_json({ "error": Json::string("bad json") }, status=400)
          return
        }
      }
      let username = jv_string(json, "username")
      let password = jv_string(json, "password")
      let role = jv_string(json, "role")
      let prefix = jv_string(json, "write_prefix")
      let actor = auth.session_role(req)
      if !can_manage_role(actor, role) ||
        !valid_user_role(role) ||
        username.length() < 3 ||
        password.length() < 12 ||
        (!prefix.is_empty() && !@lib.valid_slug(prefix)) {
        res.send_json({ "error": Json::string("invalid account") }, status=400)
        return
      }
      if meta.create_user(username, password, role, prefix) {
        res.send_json({ "ok": Json::boolean(true) })
      } else {
        res.send_json({ "error": Json::string("username exists") }, status=409)
      }
    })
    ctx.post("/api/admin/users/update", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let body = req.body.text()
      let json = @json.parse(body) catch {
        _ => {
          res.send_json({ "error": Json::string("bad json") }, status=400)
          return
        }
      }
      let id = jv_int(json, "id")
      let role = jv_string(json, "role")
      let prefix = jv_string(json, "write_prefix")
      let enabled = jv_bool(json, "enabled")
      let mut target_role = "none"
      for user in meta.list_users() {
        if user.id == id {
          target_role = user.role
        }
      }
      let actor = auth.session_role(req)
      if !can_manage_role(actor, target_role) ||
        !can_manage_role(actor, role) ||
        !valid_user_role(role) ||
        (!prefix.is_empty() && !@lib.valid_slug(prefix)) {
        res.send_json(
          { "error": Json::string("no permission or invalid") },
          status=403,
        )
        return
      }
      if meta.update_user(id, role, prefix, enabled) {
        res.send_json({ "ok": Json::boolean(true) })
      } else {
        res.send_json({ "error": Json::string("not found") }, status=404)
      }
    })
    ctx.post("/api/admin/users/password", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let body = req.body.text()
      let json = @json.parse(body) catch {
        _ => {
          res.send_json({ "error": Json::string("bad json") }, status=400)
          return
        }
      }
      let id = jv_int(json, "id")
      let password = jv_string(json, "password")
      let mut target_role = "none"
      for user in meta.list_users() {
        if user.id == id {
          target_role = user.role
        }
      }
      let actor = auth.session_role(req)
      if password.length() < 12 || !can_manage_role(actor, target_role) {
        res.send_json(
          { "error": Json::string("no permission or short password") },
          status=403,
        )
        return
      }
      if meta.reset_user_password(id, password) {
        res.send_json({ "ok": Json::boolean(true) })
      } else {
        res.send_json({ "error": Json::string("not found") }, status=404)
      }
    })

    // API key 管理
    ctx.get("/api/admin/keys", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let keys = meta.list_api_keys()
      let items = keys.map(fn(k) {
        Json::object({
          "id": Json::number(k.id.to_double()),
          "name": Json::string(k.name),
          "scopes": Json::string(k.scopes),
          "enabled": Json::boolean(k.enabled),
        })
      })
      res.send_json({ "keys": Json::array(items) })
    })
    ctx.post("/api/admin/keys", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let body = req.body.text()
      let json = @json.parse(body) catch {
        _ => {
          res.send_json({ "error": Json::string("bad json") }, status=400)
          return
        }
      }
      let name = jv_string(json, "name")
      let scopes = jv_string(json, "scopes")
      let user_id = jv_int(json, "user_id")
      let read_prefix = jv_string(json, "read_prefix")
      let write_prefix = jv_string(json, "write_prefix")
      if name.is_empty() ||
        (!read_prefix.is_empty() && !@lib.valid_slug(read_prefix)) ||
        (!write_prefix.is_empty() && !@lib.valid_slug(write_prefix)) {
        res.send_json({ "error": Json::string("invalid key") }, status=400)
        return
      }
      let plain = meta.create_api_key(
        name, scopes, user_id, read_prefix, write_prefix,
      )
      res.send_json({ "ok": Json::boolean(true), "key": Json::string(plain) })
    })
    ctx.post("/api/admin/keys/revoke", (req, res) => {
      if !auth.is_admin(req) {
        res.send_json({ "error": Json::string("admin required") }, status=403)
        return
      }
      let body = req.body.text()
      let json = @json.parse(body) catch {
        _ => {
          res.send_json({ "error": Json::string("bad json") }, status=400)
          return
        }
      }
      let id = jv_int(json, "id")
      meta.revoke_api_key(id)
      res.send_json({ "ok": Json::boolean(true) })
    })

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
        _ => "mbt-mdwiki"
      }
      res.send_json({ "title": Json::string(product_name) })
    })
    // 服务端渲染阅读页（面包屑 + 文档树 + tags + title）
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
      let page = render_doc_page(storage, meta, auth, req, slug)
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
      let page = render_doc_page(storage, meta, auth, req, slug)
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

    ctx.get("/sys/login", (_req, res) => {
      let page = render_login_page(meta)
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
          let html = @lib.render_doc_html(raw)
          let dm = @lib.document_meta(raw)
          res.send_json({
            "slug": Json::string(slug),
            "html": Json::string(html),
            "content": Json::string(raw),
            "category": Json::string(dm.category),
            "status": Json::string(dm.status),
          })
        }
        None =>
          res.send_json({ "error": Json::string("not found") }, status=404)
      }
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
      if !can_write(perm.scopes) ||
        !allowed_write_prefix(perm.write_prefix, slug) {
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
      if !can_write(perm.scopes) ||
        !allowed_write_prefix(perm.write_prefix, slug) {
        res.send_json(
          { "error": Json::string("write permission required") },
          status=403,
        )
        return
      }
      storage.delete(slug)
      res.send_json({ "ok": Json::boolean(true) })
    })
  })

  let server = @rserver.Server(api~, port~, component=@app.app)
  server.run_forever()
}

///|
/// 从 JSON 请求体解析 username / password。提取不到返回空串。
fn parse_login(body : String) -> (String, String) {
  let json = @json.parse(body) catch { _ => return ("", "") }
  match json {
    Json::Object(map) =>
      (map_get_string(map, "username"), map_get_string(map, "password"))
    _ => ("", "")
  }
}

///|
fn map_get_string(map : Map[String, Json], key : String) -> String {
  match map.get(key) {
    Some(Json::String(v)) => v
    _ => ""
  }
}

///|
struct SiteConfig {
  title : String
  public : String
  show_tree : String
  llms_mode : String
  llms_prefixes : String
}

///|
/// 从 JSON 解析站点配置。缺省字段回退到默认值。
fn parse_site(body : String) -> SiteConfig {
  let json = @json.parse(body) catch { _ => return default_site() }
  match json {
    Json::Object(map) =>
      {
        title: default_or(map_get_string(map, "title"), "mbt-mdwiki"),
        public: default_or(map_get_string(map, "public"), "true"),
        show_tree: default_or(map_get_string(map, "show_tree"), "true"),
        llms_mode: default_or(map_get_string(map, "llms_mode"), "public"),
        llms_prefixes: map_get_string(map, "llms_prefixes"),
      }
    _ => default_site()
  }
}

///|
fn default_site() -> SiteConfig {
  {
    title: "mbt-mdwiki",
    public: "true",
    show_tree: "true",
    llms_mode: "public",
    llms_prefixes: "",
  }
}

///|
fn default_or(value : String, fallback : String) -> String {
  if value.is_empty() {
    fallback
  } else {
    value
  }
}

///|
fn js_int(map : Map[String, Json], key : String) -> Int {
  match map.get(key) {
    Some(Number(n, repr=_)) => n.to_int()
    _ => 0
  }
}

///|
fn js_bool(map : Map[String, Json], key : String) -> Bool {
  match map.get(key) {
    Some(True) => true
    _ => false
  }
}

///|
fn jv_string(json : Json, key : String) -> String {
  match json {
    Json::Object(map) => map_get_string(map, key)
    _ => ""
  }
}

///|
fn jv_int(json : Json, key : String) -> Int {
  match json {
    Json::Object(map) => js_int(map, key)
    _ => 0
  }
}

///|
fn jv_bool(json : Json, key : String) -> Bool {
  match json {
    Json::Object(map) => js_bool(map, key)
    _ => true
  }
}

///|
/// 读取 .env 文件并填入 env 表（不覆盖已有环境变量）。
async fn load_dotenv(env : Map[String, String]) -> Unit {
  if !@fs.exists(".env") {
    return
  }
  let content = @utf8.decode_lossy(@fs.read_file(".env").binary()[:])
  for line in content.split("\n") {
    let line = line.trim()
    if !line.is_empty() && !line.has_prefix("#") {
      match line.find("=") {
        Some(i) if !env.contains(line[:i].trim().to_owned()) =>
          env[line[:i].trim().to_owned()] = line[i + 1:].trim().to_owned()
        _ => ()
      }
    }
  }
}

///|
/// 解析命令行 `--port` 参数（若提供则覆盖环境变量 PORT）。
fn cli_port(env : Map[String, String]) -> UInt16 {
  let args = @env.args()
  let mut found : String = ""
  let mut i = 0
  while i < args.length() {
    if args[i] == "--port" && i + 1 < args.length() {
      found = args[i + 1]
    }
    i += 1
  }
  match found {
    "" => parse_port(env)
    v => @string.parse_uint(v).to_uint16() catch { _ => 8080 }
  }
}

///|
/// 读取监听端口：优先环境变量 PORT，默认 8080。
fn parse_port(env : Map[String, String]) -> UInt16 {
  match env.get("PORT") {
    Some(v) => @string.parse_uint(v).to_uint16() catch { _ => 8080 }
    None => 8080
  }
}

///|
async fn site_product_name(meta : @lib.JsonMeta) -> String {
  match meta.get_config("site.title") {
    Some(v) if !v.is_empty() => v
    _ => "mbt-mdwiki"
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
/// 服务端渲染一篇文章为完整 HTML 页面（复用根库渲染工具）。
async fn render_doc_page(
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  auth : AuthState,
  req : @moonback.Request,
  slug : String,
) -> String {
  match storage.read(slug) {
    Some(raw) => {
      let doc = @lib.document_meta(raw)
      let html = @lib.render_doc_html(raw)
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
      let edit_link = if auth.can_edit(req) {
        "<a href=\"/edit\">进入编辑器</a>"
      } else {
        ""
      }
      "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" +
      doc.title +
      " - " +
      product_name +
      "</title><script src=\"/theme.js\"></script><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"reading-shell\"><div class=\"topbar\"><a href=\"/\">" +
      product_name +
      "</a><span class=\"account\">" +
      edit_link +
      "</span></div><div class=\"breadcrumbs\">" +
      breadcrumb +
      "</div>" +
      tree +
      "<article>" +
      html +
      tags +
      "</article></main></body></html>"
    }
    None =>
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>文档不存在</title></head><body><p>文档不存在</p></body></html>"
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
  output.write_string("# mbt-mdwiki\n\n")
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
        output.write_string(")")
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
    result.push({ slug, name, count })
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
/// 渲染独立登录页（/sys/login）：用户名/密码 + 提交登录后跳转。
async fn render_login_page(meta : @lib.JsonMeta) -> String {
  let product_name = site_product_name(meta)
  "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>登录 - " +
  product_name +
  "</title><script src=\"/theme.js\"></script><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"login-shell\"><h1 class=\"login-title\">" +
  product_name +
  "</h1><p class=\"login-sub\">请登录以继续</p><form id=\"login-form\"><div class=\"field\"><label>用户名</label><input id=\"login-user\" autocomplete=\"username\"></div><div class=\"field\"><label>密码</label><input id=\"login-pass\" type=\"password\" autocomplete=\"current-password\"></div><button type=\"submit\" class=\"button\">登录</button></form><p id=\"login-msg\" class=\"notice\"></p><p class=\"login-back\"><a href=\"/\">返回文档站</a></p></main><script>(function(){var f=document.getElementById('login-form');if(f){f.addEventListener('submit',function(e){e.preventDefault();var u=document.getElementById('login-user').value,p=document.getElementById('login-pass').value,m=document.getElementById('login-msg');fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p})}).then(function(r){if(r.ok){location.href='/'}else if(m){m.textContent='登录失败：请检查用户名/密码'}}).catch(function(){if(m){m.textContent='网络错误，请重试'}})})}})()</script></body></html>"
}
