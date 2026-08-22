///|
struct StartupSession {
  bootstrap_key : String
  session_token : String
  mut consumed : Bool
}

///|
struct AdminSession {
  bootstrap_key : String
  session_token : String
  mut consumed : Bool
}

///|
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let meta = @lib.JsonMeta::open("meta")
  let startup_key = @lib.generate_api_key()
  let startup_session : StartupSession = {
    bootstrap_key: startup_key,
    session_token: @lib.generate_api_key(),
    consumed: false,
  }
  let admin_session : AdminSession = {
    bootstrap_key: @lib.generate_api_key(),
    session_token: @lib.generate_api_key(),
    consumed: false,
  }
  let port = match @env.get_env_var("PORT") {
    Some(p) => p
    None => "8001"
  }
  let server = @http.Server(@socket.Addr::parse("0.0.0.0:" + port))
  println("mbt-mdwiki listening on http://127.0.0.1:\{port}")
  println("客户端 Key（本次启动仅显示一次）：\{startup_key}")
  println(
    "客户端地址（打开后会自动隐藏 Key）：http://127.0.0.1:\{port}/?api_key=\{startup_key}",
  )
  println("文档首页：http://127.0.0.1:\{port}/d/index")
  println(
    "后台地址（一次性登录）：http://127.0.0.1:\{port}/admin/login?admin_key=\{admin_session.bootstrap_key}",
  )
  println(
    "ADMIN_TOKEN 表单登录：\{if @env.get_env_var("ADMIN_TOKEN") is Some(_) { "已配置" } else { "未配置，将仅使用一次性后台地址" }}",
  )
  println("REST API: http://127.0.0.1:\{port}/api/v1/docs")
  server.run_forever() <| ((request, body, conn) => {
    handle(request, body, conn, storage, meta, startup_session, admin_session)
  })
}

///|
async fn serve_static_file(
  conn : @http.ServerConnection,
  path : String,
  content_type : String,
) -> Unit {
  if !@fs.exists(path) {
    respond(
      conn, 503, "text/plain; charset=utf-8", "missing frontend resource; run `make build-frontend`",
    )
    return
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": content_type,
    "Content-Length": file.size().to_string(),
  })
  ..write_reader(file)
  .end_response()
}

///|
async fn respond(
  conn : @http.ServerConnection,
  code : Int,
  content_type : String,
  body : String,
) -> Unit {
  conn.send_response(code, "OK", extra_headers={ "Content-Type": content_type })
  conn.write_string(body)
  conn.end_response()
}

///|
async fn respond_error(
  conn : @http.ServerConnection,
  code : Int,
  msg : String,
) -> Unit {
  let body = "{\"error\":{\"code\":\"" +
    code.to_string() +
    "\",\"message\":\"" +
    msg +
    "\"}}"
  respond(conn, code, "application/json", body)
}

///|
async fn respond_with_headers(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
  content_type : String,
  body : String,
  headers : Map[@http.CaseInsensitiveString, String],
) -> Unit {
  headers["Content-Type"] = content_type
  conn.send_response(code, reason, extra_headers=headers)
  conn.write_string(body)
  conn.end_response()
}

///|
async fn handle(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  startup_session : StartupSession,
  admin_session : AdminSession,
) -> Unit {
  let path = request.path
  if request.meth is Get && path == "/health" {
    respond(conn, 200, "text/plain", "ok")
    return
  }
  if request.meth is Get {
    let (clean_path, query) = split_query(path)
    if clean_path == "/" {
      match query_param(query, "api_key") {
        Some(key) if key == startup_session.bootstrap_key &&
          !startup_session.consumed => {
          startup_session.consumed = true
          respond_with_headers(
            conn,
            302,
            "Found",
            "text/plain",
            "正在进入文档站……",
            {
              "Location": "/",
              "Set-Cookie": "mbt_session=\{startup_session.session_token}; Path=/; HttpOnly; SameSite=Lax",
            },
          )
        }
        _ =>
          serve_static_file(
            conn, "frontend/index.html", "text/html; charset=utf-8",
          )
      }
      return
    }
  }
  if request.meth is Get && path == "/frontend.js" {
    serve_static_file(
      conn, "_build/js/debug/build/frontend/frontend.js", "application/javascript; charset=utf-8",
    )
    return
  }
  if path.has_prefix("/api/v1/") {
    handle_api(request, body, conn, storage, meta, startup_session)
    return
  }
  if path.has_prefix("/admin") {
    handle_admin(request, body, conn, storage, meta, admin_session)
    return
  }
  if request.meth is Get && path.has_prefix("/d/") {
    render_doc_page(request, conn, storage)
    return
  }
  respond(conn, 404, "text/plain", "Not Found")
}

///|
async fn handle_api(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  startup_session : StartupSession,
) -> Unit {
  // 鉴权：优先 Bearer；启动链接兑换到的进程内会话只在本次服务运行中有效。
  let scopes = match extract_bearer(request) {
    Some(key) => meta.verify_api_key(key)
    None =>
      match extract_cookie(request, "mbt_session") {
        Some(token) if token == startup_session.session_token =>
          Some("read,write")
        _ => None
      }
  }
  let scopes = match scopes {
    Some(s) => s
    None => {
      respond_error(conn, 401, "invalid or missing API key")
      return
    }
  }
  // 路由解析：/api/v1/<resource>[/<slug>][?query]
  let rest = request.path["/api/v1/".length():]
  let (rest_path, _query) = split_query(rest)
  let (resource, slug) = match rest_path.find("/") {
    Some(i) => (rest_path[:i].to_owned(), Some(rest_path[i + 1:].to_owned()))
    None => (rest_path, None)
  }
  match (request.meth, resource) {
    (Get, "docs") => {
      if !can_read(scopes) {
        respond_error(conn, 403, "read permission required")
        return
      }
      match slug {
        Some(s) => read_doc(request, conn, storage, s)
        None => list_docs(conn, storage)
      }
    }
    (Put, "docs") => {
      if !can_write(scopes) {
        respond_error(conn, 403, "write permission required")
        return
      }
      match slug {
        Some(s) => write_doc(body, conn, storage, s)
        None => respond_error(conn, 400, "slug required in path")
      }
    }
    (Delete, "docs") => {
      if !can_write(scopes) {
        respond_error(conn, 403, "write permission required")
        return
      }
      match slug {
        Some(s) => delete_doc(conn, storage, s)
        None => respond_error(conn, 400, "slug required in path")
      }
    }
    (Get, "search") => search_docs(request, conn, storage)
    (Get, "config") => {
      if !can_read(scopes) {
        respond_error(conn, 403, "read permission required")
        return
      }
      config_docs(conn, meta)
    }
    _ => respond_error(conn, 404, "endpoint not found")
  }
}

///|
fn can_read(scopes : String) -> Bool {
  for s in scopes.split(",") {
    if s == "read" || s == "write" {
      return true
    }
  }
  false
}

///|
fn can_write(scopes : String) -> Bool {
  for s in scopes.split(",") {
    if s == "write" {
      return true
    }
  }
  false
}

///|
fn extract_bearer(request : @http.Request) -> String? {
  for k, v in request.headers {
    if k == "authorization" || k == "Authorization" {
      if v.has_prefix("Bearer ") {
        let key = v["Bearer ".length():].to_owned()
        if !key.is_empty() {
          return Some(key)
        }
      }
    }
  }
  None
}

///|
fn extract_cookie(request : @http.Request, name : String) -> String? {
  for k, v in request.headers {
    if k == "cookie" || k == "Cookie" {
      for item in v.split(";") {
        let item = item.trim()
        if item.has_prefix(name + "=") {
          return Some(item[name.length() + 1:].to_owned())
        }
      }
    }
  }
  None
}

///|
fn split_query(path : StringView) -> (String, String) {
  match path.find("?") {
    Some(i) => (path[:i].to_owned(), path[i + 1:].to_owned())
    None => (path.to_owned(), "")
  }
}

///|
fn query_param(query : String, name : String) -> String? {
  for part in query.split("&") {
    if part.has_prefix(name + "=") {
      return Some(part[name.length() + 1:].to_owned())
    }
  }
  None
}

///|
async fn handle_admin(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  _storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  admin_session : AdminSession,
) -> Unit {
  let path = request.path
  let (clean_path, query) = split_query(path)
  if request.meth is Get && clean_path == "/admin/login" {
    match query_param(query, "admin_key") {
      Some(key) if key == admin_session.bootstrap_key && !admin_session.consumed => {
        admin_session.consumed = true
        respond_with_headers(
          conn,
          302,
          "Found",
          "text/plain",
          "正在进入后台……",
          {
            "Location": "/admin/keys",
            "Set-Cookie": "mbt_admin_session=\{admin_session.session_token}; Path=/admin; HttpOnly; SameSite=Lax",
          },
        )
      }
      _ => admin_login_page(conn, "")
    }
    return
  }
  if request.meth is Post && clean_path == "/admin/login" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let token = form_value(form, "token")
    let expected = match @env.get_env_var("ADMIN_TOKEN") {
      Some(value) => value
      None => ""
    }
    if expected != "" && token == expected {
      respond_with_headers(conn, 302, "Found", "text/plain", "redirecting", {
        "Location": "/admin/keys",
        "Set-Cookie": "admin_token=" + token + "; Path=/admin; HttpOnly",
      })
    } else {
      admin_login_page(conn, "invalid admin token")
    }
    return
  }
  if !admin_authenticated(request, admin_session) {
    respond_with_headers(conn, 302, "Found", "text/plain", "login required", {
      "Location": "/admin/login",
    })
    return
  }
  if request.meth is Get && clean_path == "/admin/keys" {
    admin_keys_page(conn, meta)
    return
  }
  if request.meth is Post && clean_path == "/admin/keys" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let name = form_value(form, "name")
    let scopes = form_value(form, "scopes")
    let key = meta.create_api_key(
      name,
      if scopes == "" {
        "read"
      } else {
        scopes
      },
    )
    admin_keys_page_with_notice(conn, meta, "created key: " + key)
    return
  }
  if request.meth is Post && clean_path == "/admin/keys/revoke" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let id = parse_nonnegative_int(form_value(form, "id"))
    meta.revoke_api_key(id)
    admin_keys_page_with_notice(conn, meta, "key revoked")
    return
  }
  respond(conn, 404, "text/plain", "Not Found")
}

///|
fn parse_nonnegative_int(value : String) -> Int {
  let mut result = 0
  for c in value {
    if c < '0' || c > '9' {
      return 0
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn form_value(form : String, name : String) -> String {
  for part in form.split("&") {
    if part.has_prefix(name + "=") {
      return part[name.length() + 1:].to_owned()
    }
  }
  ""
}

///|
fn admin_authenticated(
  request : @http.Request,
  admin_session : AdminSession,
) -> Bool {
  for key, value in request.headers {
    if key == "cookie" || key == "Cookie" {
      if value.contains("mbt_admin_session=" + admin_session.session_token) {
        return true
      }
    }
  }
  let expected = match @env.get_env_var("ADMIN_TOKEN") {
    Some(value) => value
    None => ""
  }
  if expected.is_empty() {
    false
  } else {
    match extract_cookie(request, "admin_token") {
      Some(value) => value == expected
      None => false
    }
  }
}

///|
async fn admin_login_page(
  conn : @http.ServerConnection,
  notice : String,
) -> Unit {
  let page = "<!doctype html><html><body><h1>mbt-mdwiki admin</h1><p>" +
    notice +
    "</p><form method=\"post\" action=\"/admin/login\"><label>Admin token <input name=\"token\" type=\"password\"></label><button>Login</button></form></body></html>"
  respond(conn, 200, "text/html; charset=utf-8", page)
}

///|
async fn admin_keys_page(
  conn : @http.ServerConnection,
  meta : @lib.JsonMeta,
) -> Unit {
  admin_keys_page_with_notice(conn, meta, "")
}

///|
async fn admin_keys_page_with_notice(
  conn : @http.ServerConnection,
  meta : @lib.JsonMeta,
  notice : String,
) -> Unit {
  let rows = StringBuilder()
  for key in meta.list_api_keys() {
    rows.write_string("<li>#")
    rows.write_string(key.id.to_string())
    rows.write_string(" ")
    rows.write_string(key.name)
    rows.write_string(" [")
    rows.write_string(key.scopes)
    rows.write_string(
      "] <form method=\"post\" action=\"/admin/keys/revoke\" style=\"display:inline\"><input type=\"hidden\" name=\"id\" value=\"",
    )
    rows.write_string(key.id.to_string())
    rows.write_string("\"><button>Revoke</button></form></li>")
  }
  let page = "<!doctype html><html><body><h1>API keys</h1><p>" +
    notice +
    "</p><ul>" +
    rows.to_string() +
    "</ul><h2>Create key</h2><form method=\"post\" action=\"/admin/keys\"><input name=\"name\" placeholder=\"name\"><select name=\"scopes\"><option value=\"read\">read</option><option value=\"read,write\">read,write</option></select><button>Create</button></form></body></html>"
  respond(conn, 200, "text/html; charset=utf-8", page)
}

///|
async fn render_doc_page(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let (path, _) = split_query(request.path)
  let slug = path[3:].to_owned()
  match storage.read(slug) {
    Some(content) => {
      let html = @cmark_html.render(content, safe=true)
      let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>mbt-mdwiki</title></head><body>" +
        html +
        "</body></html>"
      respond(conn, 200, "text/html; charset=utf-8", page)
    }
    None => respond_error(conn, 404, "document not found")
  }
}

///|
async fn list_docs(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let slugs = storage.list()
  let items = slugs.map(fn(slug) { "\"" + slug + "\"" }).join(",")
  respond(conn, 200, "application/json", "{\"docs\":[" + items + "]}")
}

///|
async fn read_doc(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  slug : String,
) -> Unit {
  let (_, query) = split_query(request.path)
  match storage.read(slug) {
    Some(content) =>
      // D3 之前 format=html 先回 raw
      if query_param(query, "format") == Some("html") {
        respond(conn, 200, "text/html", content)
      } else {
        respond(conn, 200, "text/markdown; charset=utf-8", content)
      }
    None => respond_error(conn, 404, "document not found")
  }
}

///|
async fn write_doc(
  body : &@io.Reader,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  slug : String,
) -> Unit {
  let content = @utf8.decode_lossy(body.read_all().binary()[:])
  let success = try {
    storage.write(slug, content)
    true
  } catch {
    _ => false
  }
  if success {
    respond(conn, 200, "application/json", "{\"ok\":true}")
  } else {
    respond_error(conn, 400, "invalid slug")
  }
}

///|
async fn delete_doc(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  slug : String,
) -> Unit {
  storage.delete(slug)
  respond(conn, 200, "application/json", "{\"ok\":true}")
}

///|
async fn search_docs(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let (_, query) = split_query(request.path)
  let q = match query_param(query, "q") {
    Some(x) => x
    None => {
      respond_error(conn, 400, "missing q parameter")
      return
    }
  }
  let hits : Array[String] = []
  for slug in storage.list() {
    match storage.read(slug) {
      Some(content) =>
        if slug.contains(q) || content.contains(q) {
          hits.push(slug)
        }
      None => ()
    }
  }
  let items = hits.map(fn(s) { "\"" + s + "\"" }).join(",")
  respond(conn, 200, "application/json", "{\"results\":[" + items + "]}")
}

///|
async fn config_docs(
  conn : @http.ServerConnection,
  meta : @lib.JsonMeta,
) -> Unit {
  let title = match meta.get_config("site.title") {
    Some(t) => t
    None => "mbt-mdwiki"
  }
  let desc = match meta.get_config("site.description") {
    Some(d) => d
    None => ""
  }
  let body = "{\"site\":{\"title\":\"" +
    title +
    "\",\"description\":\"" +
    desc +
    "\"}}"
  respond(conn, 200, "application/json", body)
}
