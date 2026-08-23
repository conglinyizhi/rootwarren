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
      if auth.admin_login(username, password) is Some(token) {
        res.send_json({ "token": Json::string(token), "role": Json::string("admin") })
      } else if auth.register_user(match meta.verify_user(username, password) {
        Some(user) => user
        None => {
          res.send_json({ "error": Json::string("invalid credentials") }, status=401)
          return
        }
      }) is Some(token) {
        res.send_json({ "token": Json::string(token), "role": Json::string("user") })
      } else {
        res.send_json({ "error": Json::string("invalid credentials") }, status=401)
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
