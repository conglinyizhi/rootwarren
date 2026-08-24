// 后台管理路由：/api/admin/*（用户、站点设置、API 密钥）。

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
        title: default_or(map_get_string(map, "title"), "rootwarren"),
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
    title: "rootwarren",
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
/// 注册后台管理路由（仅管理员可访问）。
fn register_admin_routes(
  ctx : @moonback.ModuleContext,
  meta : @lib.JsonMeta,
  auth : AuthState,
) -> Unit raise {
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
      None => "rootwarren"
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
}
