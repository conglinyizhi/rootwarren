///|
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let meta = @lib.JsonMeta::open("meta")
  let env = @env.get_env_vars()
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
    ctx.get("/health", (_req, res) => {
      res.send_json({ "status": "ok" })
    })

    // 认证
    ctx.post("/api/auth/login", (req, res) => {
      let body = req.body.text()
      let (username, password) = parse_login(body)
      let result = if auth.admin_login(username, password) is Some(token) {
        Some((token, "admin"))
      } else {
        match meta.verify_user(username, password) {
          Some(user) => match auth.register_user(user) {
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
        None => res.send_json({ "error": Json::string("invalid credentials") }, status=401)
      }
    })
    ctx.post("/api/auth/logout", (req, res) => {
      auth.logout(req)
      res.send_json({ "ok": Json::boolean(true) })
    })
    ctx.get("/api/auth/me", (req, res) => {
      match auth.authenticate(req) {
        Some(subject) => res.send_json({ "subject": Json::string(subject) })
        None => res.send_json({ "error": Json::string("unauthorized") }, status=401)
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

    ctx.get("/api/v1/config", (_req, res) => {
      let product_name = match meta.get_config("site.title") {
        Some(v) if !v.is_empty() => v
        _ => "mbt-mdwiki"
      }
      res.send_json({ "title": Json::string(product_name) })
    })
    ctx.get("/api/v1/docs", (_req, res) => {
      let slugs = storage.list()
      let items = slugs.map(fn(slug) { Json::string(slug) })
      res.send_json({ "docs": Json::array(items) })
    })
    ctx.get("/api/v1/docs/*slug", (req, res) => {
      let slug = match req.params.get("slug") {
        Some(s) => s.to_owned()
        None => {
          res.send_text("missing slug", status=400)
          return
        }
      }
      match storage.read(slug) {
        Some(raw) => {
          let html = @lib.render_doc_html(raw)
          res.send_json({ "slug": Json::string(slug), "html": Json::string(html) })
        }
        None => {
          res.send_json({ "error": Json::string("not found") }, status=404)
        }
      }
    })
    ctx.add_route(@http.RequestMethod::Put, "/api/v1/docs/*slug", (req, res) => {
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
      if !auth.can_edit(req) {
        res.send_json({ "error": Json::string("write permission required") }, status=403)
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
      if !auth.can_edit(req) {
        res.send_json({ "error": Json::string("write permission required") }, status=403)
        return
      }
      storage.delete(slug)
      res.send_json({ "ok": Json::boolean(true) })
    })
  })

  let server = @rserver.Server(api=api, port=8080, component=@app.app)
  server.run_forever()
}

///|
/// 从 JSON 请求体解析 username / password。提取不到返回空串。
fn parse_login(body : String) -> (String, String) {
  let json = @json.parse(body) catch { _ => return ("", "") }
  match json {
    Json::Object(map) =>
      (
        map_get_string(map, "username"),
        map_get_string(map, "password"),
      )
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
  if value.is_empty() { fallback } else { value }
}
