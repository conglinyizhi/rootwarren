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
  let command = @argparse.Command("mbt-mdwiki", options=[
    @argparse.OptionArg(
      "ip",
      long="ip",
      about="监听 IP 地址",
      env="MBT_MDWIKI_IP",
      default_values=["0.0.0.0"],
    ),
    @argparse.OptionArg("port", long="port", about="监听端口", env="PORT", default_values=[
      "8001",
    ]),
  ])
  let raw_args = @env.args()
  let argv = match raw_args.get(0) {
    Some(first) if first.has_suffix(".exe") || first.has_suffix("/main") =>
      raw_args[1:]
    _ => raw_args[:]
  }
  let args = command.parse(argv~, env=@env.get_env_vars())
  let ip = match args.values.get("ip") {
    Some([value, ..]) => value
    _ => "0.0.0.0"
  }
  let port = match args.values.get("port") {
    Some([value, ..]) => value
    _ => "8001"
  }
  let server = @http.Server(@socket.Addr::parse(ip + ":" + port)) catch {
    err => {
      println(
        "启动失败：无法监听 \{ip}:\{port}，该地址或端口可能已被占用。",
      )
      println("详细错误：\{err}")
      return
    }
  }
  println("mbt-mdwiki listening on http://\{ip}:\{port}")
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
  @signal.set_global_cancellation_signals([
    @signal.Signal::SIGINT,
    @signal.Signal::SIGTERM,
    @signal.Signal::SIGHUP,
  ])
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
        _ => {
          let public = site_is_public(meta)
          let can_edit = session_authenticated(
            request, startup_session, admin_session,
          )
          if public || can_edit {
            render_doc_page_by_slug(conn, storage, meta, "index", can_edit)
          } else {
            respond_error(
              conn, 403, "site is private; use the admin bootstrap URL",
            )
          }
        }
      }
      return
    }
  }
  if request.meth is Get && path == "/edit" {
    if session_authenticated(request, startup_session, admin_session) {
      serve_static_file(conn, "frontend/index.html", "text/html; charset=utf-8")
    } else {
      respond_with_headers(
        conn,
        302,
        "Found",
        "text/plain",
        "请先登录编辑会话",
        { "Location": "/" },
      )
    }
    return
  }
  if request.meth is Get && path == "/frontend.js" {
    serve_static_file(
      conn, "_build/js/debug/build/frontend/frontend.js", "application/javascript; charset=utf-8",
    )
    return
  }
  if request.meth is Get && path == "/llms.txt" {
    if site_is_public(meta) {
      serve_llms(conn, storage)
    } else {
      respond_error(conn, 403, "site is private; use the admin bootstrap URL")
    }
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
    if site_is_public(meta) ||
      session_authenticated(request, startup_session, admin_session) {
      render_doc_page(
        request,
        conn,
        storage,
        session_authenticated(request, startup_session, admin_session),
      )
    } else {
      respond_error(conn, 403, "site is private; use the admin bootstrap URL")
    }
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
    admin_keys_page_with_notice(conn, meta, "已创建访问密钥：" + key)
    return
  }
  if request.meth is Post && clean_path == "/admin/keys/revoke" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let id = parse_nonnegative_int(form_value(form, "id"))
    meta.revoke_api_key(id)
    admin_keys_page_with_notice(conn, meta, "密钥已吊销")
    return
  }
  if request.meth is Post && clean_path == "/admin/site" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let public = form_value(form, "public") == "true"
    let show_tree = form_value(form, "show_tree") != "false"
    meta.set_config("site.public", if public { "true" } else { "false" })
    meta.set_config("site.show_tree", if show_tree { "true" } else { "false" })
    admin_keys_page_with_notice(conn, meta, "网站公开设置已保存")
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
  let public = site_is_public(meta)
  let show_tree = site_show_tree(meta)
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
  let page = "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>后台管理 - mbt-mdwiki</title><style>body{font-family:Inter,\"Noto Sans SC\",sans-serif;max-width:900px;margin:0 auto;padding:32px 20px;background:#111518;color:#d8dfda}h1{font-weight:500}section{border:1px solid #39463d;border-radius:6px;padding:22px;margin:18px 0;background:#171c1a}fieldset{border:1px solid #3d4d41;border-radius:4px;padding:14px;margin:14px 0}legend{color:#b9caa9;padding:0 6px}label{display:block;margin:10px 0;color:#c5cec7}button{padding:8px 12px;border:1px solid #718a61;border-radius:4px;background:#263322;color:#e4eedf}input,select{padding:8px;background:#111817;color:#e1e9e2;border:1px solid #48574d;border-radius:3px}li{margin:10px 0}</style></head><body><h1>mbt-mdwiki 后台管理</h1><p>" +
    notice +
    "</p><section><h2>网站访问</h2><p>当前状态：" +
    (if public { "公开浏览" } else { "仅登录可见" }) +
    "</p><form method=\"post\" action=\"/admin/site\"><fieldset><legend>匿名阅读权限</legend><label><input type=\"radio\" name=\"public\" value=\"true\"" +
    (if public { " checked" } else { "" }) +
    "> 允许未登录用户阅读文档</label><label><input type=\"radio\" name=\"public\" value=\"false\"" +
    (if !public { " checked" } else { "" }) +
    "> 仅登录后允许阅读</label></fieldset><fieldset><legend>阅读页导航</legend><label><input type=\"radio\" name=\"show_tree\" value=\"true\"" +
    (if show_tree { " checked" } else { "" }) +
    "> 在阅读页显示文档层级</label><label><input type=\"radio\" name=\"show_tree\" value=\"false\"" +
    (if !show_tree { " checked" } else { "" }) +
    "> 隐藏文档层级</label></fieldset><button>保存网站访问设置</button></form></section><section><h2>访问密钥</h2><ul>" +
    rows.to_string() +
    "</ul><h3>创建新密钥</h3><form method=\"post\" action=\"/admin/keys\"><input name=\"name\" placeholder=\"密钥名称\"><select name=\"scopes\"><option value=\"read\">只读</option><option value=\"read,write\">读写</option></select><button>创建密钥</button></form></section></body></html>"
  respond(conn, 200, "text/html; charset=utf-8", page)
}

///|
async fn site_is_public(meta : @lib.JsonMeta) -> Bool {
  match meta.get_config("site.public") {
    Some(value) => value != "false"
    None => true
  }
}

///|
async fn site_show_tree(meta : @lib.JsonMeta) -> Bool {
  match meta.get_config("site.show_tree") {
    Some(value) => value != "false"
    None => true
  }
}

///|
fn session_authenticated(
  request : @http.Request,
  startup_session : StartupSession,
  admin_session : AdminSession,
) -> Bool {
  match extract_cookie(request, "mbt_session") {
    Some(token) if token == startup_session.session_token => true
    _ => admin_authenticated(request, admin_session)
  }
}

///|
struct DocumentMeta {
  title : String
  tags : String
  body : String
}

///|
fn rewrite_wiki_links(html : String) -> String {
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
fn document_meta(raw : String) -> DocumentMeta {
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
    return { title: fallback_title, tags: "", body: raw }
  }
  let end = match raw.find("\n---\n") {
    Some(i) => i
    None => return { title: fallback_title, tags: "", body: raw }
  }
  let header = raw[4:end]
  let body = raw[end + 5:].to_owned()
  let mut title = fallback_title
  let mut tags = ""
  for line in header.split("\n") {
    let line = line.to_owned()
    if line.has_prefix("title:") {
      title = line[6:].trim().to_owned()
    } else if line.has_prefix("tags:") {
      tags = line[5:].trim().to_owned()
    }
  }
  { title, tags, body }
}

///|
async fn render_doc_page(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  can_edit : Bool,
) -> Unit {
  let (path, _) = split_query(request.path)
  render_doc_page_by_slug(
    conn,
    storage,
    @lib.JsonMeta::open("meta"),
    path[3:].to_owned(),
    can_edit,
  )
}

///|
async fn render_doc_page_by_slug(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  meta_store : @lib.JsonMeta,
  slug : String,
  can_edit : Bool,
) -> Unit {
  match storage.read(slug) {
    Some(content) => {
      let meta = document_meta(content)
      let html = @cmark_html.render(meta.body, safe=true)
      let html = rewrite_wiki_links(html)
      let tags = if meta.tags.is_empty() {
        ""
      } else {
        "<p><small>标签：" + meta.tags + "</small></p>"
      }
      let page_title = if slug == "index" {
        meta.title
      } else {
        meta.title + " - mbt-mdwiki"
      }
      let tree = if site_show_tree(meta_store) {
        let items = storage
          .list()
          .map(fn(item) {
            "<li><a href=\"/d/" + item + "\">" + item + "</a></li>"
          })
          .join("")
        "<nav><strong>文档目录</strong><ul>" + items + "</ul></nav>"
      } else {
        ""
      }
      let edit_link = if can_edit {
        "<p><a href=\"/edit\">进入编辑器</a></p>"
      } else {
        ""
      }
      let page = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" +
        page_title +
        "</title><style>:root{font-family:Inter,\"Noto Sans SC\",sans-serif;color:#d8dfda;background:#111518}body{margin:0}main{max-width:1080px;margin:0 auto;padding:28px 30px 70px}.topbar{display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #344139;padding-bottom:14px;margin-bottom:24px}nav{float:right;width:230px;margin:0 0 20px 28px;padding:16px;background:#192319;border:1px solid #334238;border-radius:5px}nav ul{padding-left:20px}nav li{margin:8px 0}article{max-width:760px;line-height:1.8}article h1,article h2,article h3{color:#eef4ee;line-height:1.3}article code{background:#202a23;padding:2px 5px;border-radius:3px}article pre{background:#0b0e0d;padding:14px;overflow:auto;border:1px solid #2e3d33}a{color:#8ebbe1}small{color:#9aa89d}@media(max-width:760px){main{padding:20px 16px}nav{float:none;width:auto;margin:0 0 24px}}</style></head><body><main><div class=\"topbar\"><a href=\"/\">mbt-mdwiki 文档站</a>" +
        edit_link +
        "</div>" +
        tree +
        "<article>" +
        html +
        tags +
        "</article></main></body></html>"
      respond(conn, 200, "text/html; charset=utf-8", page)
    }
    None => respond_error(conn, 404, "document not found")
  }
}

///|
async fn serve_llms(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let output = StringBuilder()
  output.write_string("# mbt-mdwiki\n\n")
  output.write_string("这是一个由 MoonBit 驱动的 Markdown Wiki。\n\n")
  for slug in storage.list() {
    match storage.read(slug) {
      Some(raw) => {
        let meta = document_meta(raw)
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
  respond(conn, 200, "text/plain; charset=utf-8", output.to_string())
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
