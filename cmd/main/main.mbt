///|
struct AdminSession {
  bootstrap_key : String
  session_token : String
  mut consumed : Bool
}

///|
/// 登录 provider 只负责验证凭据，会话和撤销由进程层统一管理。
struct LoginState {
  secret : String
  provider : @lib.AdminTokenProvider
  revoked : Map[String, Bool]
  subjects : Map[String, @lib.UserRecord]
  active_tokens : Map[String, String]
}

///|
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let meta = @lib.JsonMeta::open("meta")
  let env = @env.get_env_vars()
  load_dotenv(env)
  let admin_session : AdminSession = {
    bootstrap_key: @lib.generate_api_key(),
    session_token: @lib.generate_api_key(),
    consumed: false,
  }
  let configured_admin_username = match meta.get_config("auth.admin_username") {
    Some(value) if valid_username(value) => value
    _ => "operator"
  }
  let configured_admin_hash = match meta.get_config("auth.admin_key_hash") {
    Some(value) => value
    None =>
      match env.get("ADMIN_TOKEN") {
        Some(value) if !value.is_empty() => @lib.hash_api_key(value)
        _ => ""
      }
  }
  let login_state : LoginState = {
    secret: @lib.generate_session_secret(),
    provider: @lib.AdminTokenProvider::from_hash(
      configured_admin_username, configured_admin_hash,
    ),
    revoked: Map([]),
    subjects: Map([]),
    active_tokens: Map([]),
  }
  let command = @argparse.Command(
    "mbt-mdwiki",
    flags=[
      @argparse.FlagArg(
        "init-env",
        long="init-env",
        about="生成 .env 配置模板后退出",
      ),
    ],
    options=[
      @argparse.OptionArg(
        "ip",
        long="ip",
        about="监听 IP 地址",
        env="MBT_MDWIKI_IP",
        default_values=["0.0.0.0"],
      ),
      @argparse.OptionArg(
        "port",
        long="port",
        about="监听端口",
        env="PORT",
        default_values=["8001"],
      ),
    ],
  )
  let raw_args = @env.args()
  let argv = match raw_args.get(0) {
    Some(first) if first.has_suffix(".exe") || first.has_suffix("/main") =>
      raw_args[1:]
    _ => raw_args[:]
  }
  let args = command.parse(argv~, env~)
  if args.flags.get("init-env") == Some(true) {
    init_env_file()
    return
  }
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
  println("文档首页：http://\{ip}:\{port}/d/index")
  println(
    "后台地址（一次性登录）：http://127.0.0.1:\{port}/admin/login?admin_key=\{admin_session.bootstrap_key}",
  )
  println(
    "ADMIN_TOKEN 表单登录：\{if login_state.provider.configured() { "已配置" } else { "未配置，请先使用后台 admin URL 设置" }}",
  )
  println("REST API: http://127.0.0.1:\{port}/api/v1/docs")
  @signal.set_global_cancellation_signals([
    @signal.Signal::SIGINT,
    @signal.Signal::SIGTERM,
    @signal.Signal::SIGHUP,
  ])
  server.run_forever() <| ((request, body, conn) => {
    handle(request, body, conn, storage, meta, admin_session, login_state)
  })
}

///|
async fn load_dotenv(env : Map[String, String]) -> Unit {
  guard @fs.exists(".env") else { return }
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
async fn init_env_file() -> Unit {
  if @fs.exists(".env") {
    println(".env 已存在，未覆盖。")
    return
  }
  @fs.write_file(
    ".env", "# mbt-mdwiki 本地配置模板\n# 后台网页登录初始密码，用户名默认是 operator，可在后台修改\nADMIN_TOKEN=replace-me\n# 监听地址\nMBT_MDWIKI_IP=0.0.0.0\nPORT=8001\n",
  )
  println("已生成 .env 配置模板，请编辑 ADMIN_TOKEN 后再启动。")
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
  admin_session : AdminSession,
  login_state : LoginState,
) -> Unit {
  let path = request.path
  if request.meth is Get && path == "/health" {
    respond(conn, 200, "text/plain", "ok")
    return
  }
  if request.meth is Get {
    let (clean_path, _) = split_query(path)
    if clean_path == "/" {
      {
        let public = site_is_public(meta)
        let can_edit = session_can_edit(request, login_state)
        if public || can_edit {
          render_doc_page_by_slug(conn, storage, meta, "index", can_edit)
        } else {
          respond_error(
            conn, 403, "site is private; use the admin bootstrap URL",
          )
        }
      }
      return
    }
  }
  if request.meth is Get && path == "/login" {
    if session_authenticated(request, admin_session, login_state) {
      respond_with_headers(conn, 302, "Found", "text/plain", "已登录", {
        "Location": "/",
      })
    } else {
      login_page(conn, "")
    }
    return
  }
  if request.meth is Post && path == "/login" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let username = form_value(form, "username")
    let password = form_value(form, "password")
    let user = meta.verify_user(username, password)
    let valid_admin = login_state.provider.verify(username, password)
    if user is Some(_) || valid_admin {
      let subject = if valid_admin { "admin" } else { username }
      if user is Some(record) {
        login_state.subjects[subject] = record
      }
      let token = @lib.issue_jwt(login_state.secret, subject)
      login_state.active_tokens[token] = subject
      respond_with_headers(conn, 302, "Found", "text/plain", "登录成功", {
        "Location": "/",
        "Set-Cookie": "mbt_auth=\{token}; Path=/; HttpOnly; SameSite=Lax",
      })
    } else {
      login_page(
        conn,
        if !login_state.provider.configured() {
          "当前未配置管理员 Admin Key，请先使用控制台打印的后台 admin URL 进入后台设置。"
        } else {
          "用户名或密码错误。"
        },
      )
    }
    return
  }
  if request.meth is Get && path == "/logout" {
    match extract_cookie(request, "mbt_auth") {
      Some(token) => {
        login_state.revoked[token] = true
        login_state.active_tokens.remove(token)
      }
      None => ()
    }
    respond_with_headers(conn, 302, "Found", "text/plain", "已退出登录", {
      "Location": "/",
      "Set-Cookie": "mbt_auth=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax",
    })
    return
  }
  if request.meth is Get && path == "/edit" {
    if session_can_edit(request, login_state) {
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
  if request.meth is Get && path == "/site.css" {
    serve_static_file(conn, "frontend/site.css", "text/css; charset=utf-8")
    return
  }
  if request.meth is Get && path == "/frontend.js" {
    serve_static_file(
      conn, "_build/js/debug/build/frontend/frontend.js", "application/javascript; charset=utf-8",
    )
    return
  }
  if request.meth is Get && path == "/llms.txt" {
    match site_llms_mode(meta) {
      "public" => serve_llms(conn, storage, "")
      "partial" => serve_llms(conn, storage, site_llms_prefixes(meta))
      _ => respond_error(conn, 404, "llms.txt is disabled")
    }
    return
  }
  if path.has_prefix("/api/v1/") {
    handle_api(request, body, conn, storage, meta, login_state)
    return
  }
  if path.has_prefix("/admin") {
    handle_admin(request, body, conn, storage, meta, admin_session, login_state)
    return
  }
  if request.meth is Get && path.has_prefix("/d/") {
    if site_is_public(meta) ||
      session_authenticated(request, admin_session, login_state) {
      render_doc_page(
        request,
        conn,
        storage,
        session_can_edit(request, login_state),
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
  login_state : LoginState,
) -> Unit {
  // 鉴权：优先 Bearer；网页登录 JWT 只在本次服务运行中有效。
  let mut scopes = ""
  let mut read_prefix = ""
  let mut write_prefix = ""
  match extract_bearer(request) {
    Some(key) =>
      match meta.verify_api_key(key) {
        Some(record) => {
          scopes = record.scopes
          read_prefix = record.read_prefix
          write_prefix = record.write_prefix
          if record.user_id > 0 {
            match meta.find_user_by_id(record.user_id) {
              Some(user) => {
                if user.role == "none" {
                  scopes = ""
                } else if user.role == "read" {
                  scopes = "read"
                } else if user.role == "write" && !can_write(scopes) {
                  scopes = "read"
                }
                if !user.write_prefix.is_empty() {
                  write_prefix = intersect_prefix(
                    write_prefix,
                    user.write_prefix,
                  )
                }
              }
              None => scopes = ""
            }
          }
        }
        None => {
          respond_error(conn, 401, "invalid or missing API key")
          return
        }
      }
    None =>
      match extract_cookie(request, "mbt_auth") {
        Some(token) if !login_state.revoked.contains(token) =>
          match login_state.active_tokens.get(token) {
            Some(subject) if subject == "admin" => scopes = "read,write"
            Some(subject) if login_state.subjects.get(subject) is Some(user) => {
              scopes = if user.role == "write" || user.role == "admin" {
                "read,write"
              } else {
                user.role
              }
              write_prefix = user.write_prefix
            }
            _ => ()
          }
        _ => ()
      }
  }
  if scopes.is_empty() {
    respond_error(conn, 401, "invalid or missing API key")
    return
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
        Some(s) if allowed_read_prefix(read_prefix, s) =>
          read_doc(request, conn, storage, s)
        Some(_) => respond_error(conn, 403, "document outside readable range")
        None => list_docs_with_prefix(conn, storage, read_prefix)
      }
    }
    (Put, "docs") => {
      if !can_write(scopes) || !allowed_write_prefix(write_prefix, slug) {
        respond_error(conn, 403, "write permission required")
        return
      }
      match slug {
        Some(s) => write_doc(body, conn, storage, s)
        None => respond_error(conn, 400, "slug required in path")
      }
    }
    (Delete, "docs") => {
      if !can_write(scopes) || !allowed_write_prefix(write_prefix, slug) {
        respond_error(conn, 403, "write permission required")
        return
      }
      match slug {
        Some(s) => delete_doc(conn, storage, s)
        None => respond_error(conn, 400, "slug required in path")
      }
    }
    (Get, "search") =>
      if !can_read(scopes) {
        respond_error(conn, 403, "read permission required")
      } else {
        search_docs(request, conn, storage, read_prefix)
      }
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
fn allowed_read_prefix(prefix : String, slug : String) -> Bool {
  prefix.is_empty() || slug == prefix || slug.has_prefix(prefix + "/")
}

///|
fn intersect_prefix(first : String, second : String) -> String {
  if first.is_empty() {
    second
  } else if second.is_empty() {
    first
  } else if first == second || first.has_prefix(second + "/") {
    first
  } else if second.has_prefix(first + "/") {
    second
  } else {
    "__no_access__"
  }
}

///|
fn allowed_write_prefix(prefix : String, slug : String?) -> Bool {
  match slug {
    None => false
    Some(value) =>
      prefix.is_empty() || value == prefix || value.has_prefix(prefix + "/")
  }
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
  login_state : LoginState,
) -> Unit {
  let path = request.path
  let (clean_path, query) = split_query(path)
  if request.meth is Get && clean_path == "/admin/login" {
    match query_param(query, "admin_key") {
      Some(key) if key == admin_session.bootstrap_key && !admin_session.consumed => {
        admin_session.consumed = true
        let token = @lib.issue_jwt(login_state.secret, "admin")
        login_state.active_tokens[token] = "admin"
        respond_with_headers(
          conn,
          302,
          "Found",
          "text/plain",
          "正在进入后台……",
          {
            "Location": "/admin/keys",
            "Set-Cookie": "mbt_auth=\{token}; Path=/; HttpOnly; SameSite=Lax",
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
    if login_state.provider.verify(login_state.provider.username(), token) {
      let auth_token = @lib.issue_jwt(login_state.secret, "admin")
      login_state.active_tokens[auth_token] = "admin"
      respond_with_headers(conn, 302, "Found", "text/plain", "redirecting", {
        "Location": "/admin/keys",
        "Set-Cookie": "mbt_auth=\{auth_token}; Path=/; HttpOnly; SameSite=Lax",
      })
    } else {
      admin_login_page(conn, "invalid admin token")
    }
    return
  }
  if !session_is_admin(request, admin_session, login_state) {
    respond_with_headers(
      conn,
      302,
      "Found",
      "text/plain",
      "administrator login required",
      { "Location": "/admin/login" },
    )
    return
  }
  if request.meth is Get && clean_path == "/admin/keys" {
    admin_keys_page(conn, meta)
    return
  }
  if request.meth is Get && clean_path == "/admin/users" {
    admin_users_page(conn, meta, "")
    return
  }
  if request.meth is Post && clean_path == "/admin/keys" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let name = form_value(form, "name")
    let scopes = form_value(form, "scopes")
    let user_id = parse_nonnegative_int(form_value(form, "user_id"))
    let read_prefix = form_value(form, "read_prefix")
    let write_prefix = form_value(form, "write_prefix")
    if (!read_prefix.is_empty() && !@lib.valid_slug(read_prefix)) ||
      (!write_prefix.is_empty() && !@lib.valid_slug(write_prefix)) {
      admin_keys_page_with_notice(conn, meta, "API 密钥范围路径无效")
      return
    }
    let key = meta.create_api_key(
      name,
      if scopes == "" {
        "read"
      } else {
        scopes
      },
      user_id,
      read_prefix,
      write_prefix,
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
  if request.meth is Post && clean_path == "/admin/users" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let username = form_value(form, "username")
    let password = form_value(form, "password")
    let role = form_value(form, "role")
    let prefix = form_value(form, "write_prefix")
    if !valid_username(username) ||
      password.length() < 12 ||
      !valid_user_role(role) ||
      (!prefix.is_empty() && !@lib.valid_slug(prefix)) {
      admin_keys_page_with_notice(
        conn, meta, "账号、密码或权限范围无效；密码至少 12 个字符",
      )
    } else if meta.create_user(username, password, role, prefix) {
      admin_keys_page_with_notice(conn, meta, "账号已创建")
    } else {
      admin_keys_page_with_notice(conn, meta, "用户名已存在")
    }
    return
  }
  if request.meth is Post && clean_path == "/admin/users/password" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let id = parse_nonnegative_int(form_value(form, "id"))
    let password = form_value(form, "password")
    let mut target_is_admin = false
    for user in meta.list_users() {
      if user.id == id && user.role == "admin" {
        target_is_admin = true
      }
    }
    if password.length() < 12 || target_is_admin {
      admin_users_page(
        conn, meta, "密码至少 12 个字符，且不可由此重置管理员账号密码",
      )
    } else if meta.reset_user_password(id, password) {
      for token, subject in login_state.active_tokens {
        for user in meta.list_users() {
          if user.id == id && subject == user.username {
            login_state.revoked[token] = true
          }
        }
      }
      admin_users_page(conn, meta, "用户密码已重置，旧会话已撤销")
    } else {
      admin_users_page(conn, meta, "用户不存在")
    }
    return
  }
  if request.meth is Post && clean_path == "/admin/users/update" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let id = parse_nonnegative_int(form_value(form, "id"))
    let role = form_value(form, "role")
    let prefix = form_value(form, "write_prefix")
    let enabled = form_value(form, "enabled") == "true"
    if !valid_user_role(role) ||
      (!prefix.is_empty() && !@lib.valid_slug(prefix)) {
      admin_users_page(conn, meta, "权限或路径前缀无效")
    } else if meta.update_user(id, role, prefix, enabled) {
      if !enabled {
        for user in meta.list_users() {
          if user.id == id {
            for token, subject in login_state.active_tokens {
              if subject == user.username {
                login_state.revoked[token] = true
              }
            }
          }
        }
      }
      admin_users_page(conn, meta, "用户已更新")
    } else {
      admin_users_page(conn, meta, "用户不存在")
    }
    return
  }
  if request.meth is Post && clean_path == "/admin/auth" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let new_key = form_value(form, "admin_key")
    let admin_username = form_value(form, "admin_username")
    if new_key.trim().is_empty() || !valid_username(admin_username) {
      admin_keys_page_with_notice(
        conn, meta, "管理员账号或 Admin Key 无效",
      )
    } else {
      let key = new_key.trim().to_owned()
      meta.set_config("auth.admin_key_hash", @lib.hash_api_key(key))
      meta.set_config("auth.admin_username", admin_username)
      login_state.provider.set_credentials(admin_username, key)
      admin_keys_page_with_notice(conn, meta, "管理员 Admin Key 已保存")
    }
    return
  }
  if request.meth is Post && clean_path == "/admin/site" {
    let form = @utf8.decode_lossy(body.read_all().binary()[:])
    let public = form_value(form, "public") == "true"
    let show_tree = form_value(form, "show_tree") != "false"
    let product_name = form_value(form, "product_name")
    let llms_mode = form_value(form, "llms_mode")
    let llms_prefixes = form_value(form, "llms_prefixes")
    if !valid_llms_prefixes(llms_prefixes) {
      admin_keys_page_with_notice(conn, meta, "llms.txt 路径前缀无效")
      return
    }
    meta.set_config("site.public", if public { "true" } else { "false" })
    meta.set_config("site.show_tree", if show_tree { "true" } else { "false" })
    meta.set_config(
      "site.llms_mode",
      if llms_mode == "partial" || llms_mode == "disabled" {
        llms_mode
      } else {
        "public"
      },
    )
    meta.set_config("site.llms_prefixes", llms_prefixes)
    meta.set_config(
      "site.title",
      if product_name.is_empty() {
        "mbt-mdwiki"
      } else {
        product_name
      },
    )
    admin_keys_page_with_notice(
      conn, meta, "网站访问与产品名设置已保存",
    )
    return
  }
  respond(conn, 404, "text/plain", "Not Found")
}

///|
fn valid_username(value : String) -> Bool {
  if value.length() < 3 || value.length() > 32 {
    return false
  }
  for c in value {
    if !((c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-') {
      return false
    }
  }
  true
}

///|
fn valid_llms_prefixes(value : String) -> Bool {
  for prefix in value.split(",") {
    let prefix = prefix.trim().to_owned()
    if !prefix.is_empty() && !@lib.valid_slug(prefix) {
      return false
    }
  }
  true
}

///|
fn valid_user_role(value : String) -> Bool {
  value == "admin" || value == "none" || value == "read" || value == "write"
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
      return part[name.length() + 1:].to_owned().replace_all(old="+", new=" ")
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
  false
}

///|
async fn login_page(conn : @http.ServerConnection, notice : String) -> Unit {
  let page = "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>登录</title><link rel=\"stylesheet\" href=\"/site.css\"></head><body class=\"login-shell\"><section class=\"panel\"><h1>登录</h1><p>" +
    notice +
    "</p><form method=\"post\" action=\"/login\"><div class=\"field\"><label for=\"username\">用户名</label><input id=\"username\" name=\"username\" autocomplete=\"username\"></div><div class=\"field\"><label for=\"password\">密码</label><input id=\"password\" name=\"password\" type=\"password\" autocomplete=\"current-password\"></div><button type=\"submit\">登录</button></form><a class=\"button\" href=\"/\">返回文档</a></section></body></html>"
  respond(conn, 200, "text/html; charset=utf-8", page)
}

///|
async fn admin_login_page(
  conn : @http.ServerConnection,
  notice : String,
) -> Unit {
  let page = "<!doctype html><html><body><h1>后台登录</h1><p>" +
    notice +
    "</p><form method=\"post\" action=\"/admin/login\"><label>管理员 Admin Key <input name=\"token\" type=\"password\" autocomplete=\"current-password\"></label><button>Login</button></form></body></html>"
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
  let key_user_options = StringBuilder()
  key_user_options.write_string("<option value=\"0\">不绑定用户</option>")
  let user_rows = StringBuilder()
  let users = meta.list_users()
  for user in users {
    if user.enabled {
      key_user_options.write_string("<option value=\"")
      key_user_options.write_string(user.id.to_string())
      key_user_options.write_string("\">")
      key_user_options.write_string(user.username)
      key_user_options.write_string("</option>")
    }
  }
  for i in 0..<users.length() {
    if i >= 10 {
      break
    }
    let user = users[i]
    user_rows.write_string(
      "<tr><td>" +
      user.username +
      "</td><td>" +
      user.role +
      "</td><td>" +
      (if user.write_prefix.is_empty() { "全部" } else { user.write_prefix }) +
      "</td><td>" +
      (if user.enabled { "启用" } else { "禁用" }) +
      "</td></tr>",
    )
  }
  let public = site_is_public(meta)
  let show_tree = site_show_tree(meta)
  let llms_mode = site_llms_mode(meta)
  let llms_prefixes = site_llms_prefixes(meta)
  let product_name = site_product_name(meta)
  let admin_username = match meta.get_config("auth.admin_username") {
    Some(value) if !value.is_empty() => value
    _ => "operator"
  }
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
  let page = "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>后台管理 - " +
    product_name +
    "</title><link rel=\"stylesheet\" href=\"/site.css\"></head><body><div class=\"layout\"><aside class=\"sidebar\"><strong>" +
    product_name +
    "</strong><a href=\"#site\">网站设置</a><a href=\"#users\">用户与权限</a><a href=\"#keys\">API 密钥</a><a href=\"/\">返回网站</a></aside><main><h1>后台管理</h1><p>" +
    notice +
    "</p><section id=\"site\"><h2>网站访问</h2><p>当前状态：" +
    (if public { "公开浏览" } else { "仅登录可见" }) +
    "</p><form method=\"post\" action=\"/admin/site\"><fieldset><legend>匿名阅读权限</legend><label><input type=\"radio\" name=\"public\" value=\"true\"" +
    (if public { " checked" } else { "" }) +
    "> 允许未登录用户阅读文档</label><label><input type=\"radio\" name=\"public\" value=\"false\"" +
    (if !public { " checked" } else { "" }) +
    "> 仅登录后允许阅读</label></fieldset><fieldset><legend>阅读页导航</legend><label><input type=\"radio\" name=\"show_tree\" value=\"true\"" +
    (if show_tree { " checked" } else { "" }) +
    "> 在阅读页显示文档层级</label><label><input type=\"radio\" name=\"show_tree\" value=\"false\"" +
    (if !show_tree { " checked" } else { "" }) +
    "> 隐藏文档层级</label></fieldset><fieldset><legend>llms.txt 访问</legend><label><input type=\"radio\" name=\"llms_mode\" value=\"public\"" +
    (if llms_mode == "public" { " checked" } else { "" }) +
    "> 完全开放</label><label><input type=\"radio\" name=\"llms_mode\" value=\"partial\"" +
    (if llms_mode == "partial" { " checked" } else { "" }) +
    "> 仅部分路由开放</label><label><input type=\"radio\" name=\"llms_mode\" value=\"disabled\"" +
    (if llms_mode == "disabled" { " checked" } else { "" }) +
    "> 停用</label><label>开放主题前缀<input name=\"llms_prefixes\" value=\"" +
    llms_prefixes +
    "\" placeholder=\"例如 guide,reference\"></label></fieldset><label>产品名<input name=\"product_name\" value=\"" +
    product_name +
    "\" placeholder=\"mbt-mdwiki\"></label><button>保存网站设置</button></form></section><section id=\"keys\"><h2>访问密钥</h2><ul>" +
    rows.to_string() +
    "</ul><h3>创建新密钥</h3><form method=\"post\" action=\"/admin/keys\"><label>密钥名称<input name=\"name\" required></label><label>绑定用户<select name=\"user_id\">" +
    key_user_options.to_string() +
    "</select></label><label>基础权限<select name=\"scopes\"><option value=\"read\">只读</option><option value=\"read,write\">读写</option></select></label><label>可读路径前缀<input name=\"read_prefix\" placeholder=\"例如 guide\"></label><label>可写路径前缀<input name=\"write_prefix\" placeholder=\"例如 guide\"></label><button>创建密钥</button></form></section><section id=\"users\"><h2>用户与权限</h2><table class=\"user-table\"><thead><tr><th>账号</th><th>权限</th><th>可写范围</th><th>状态</th></tr></thead><tbody>" +
    user_rows.to_string() +
    "</tbody></table><a class=\"section-link\" href=\"/admin/users\">查看全部用户与详情</a><h3>创建账号</h3><form method=\"post\" action=\"/admin/users\"><label>用户名<input name=\"username\" required></label><label>密码<input name=\"password\" type=\"password\" minlength=\"12\" required></label><label>权限<select name=\"role\"><option value=\"read\">只读文档</option><option value=\"write\">可修改文档</option><option value=\"none\">禁止访问</option><option value=\"admin\">管理员</option></select></label><label>可写路径前缀<input name=\"write_prefix\" placeholder=\"例如 guide\"></label><button>创建用户</button></form></section><section><h2>管理员登录</h2><p>设置后使用这里配置的管理员用户名和 Admin Key 登录，默认用户名为 <code>" +
    admin_username +
    "</code>。</p><form method=\"post\" action=\"/admin/auth\"><label>管理员用户名<input name=\"admin_username\" value=\"" +
    admin_username +
    "\" required></label><label>Admin Key<input name=\"admin_key\" type=\"password\" autocomplete=\"new-password\" placeholder=\"输入新的管理员 Admin Key\"></label><button>保存管理员凭据</button></form></section></main></div></body></html>"
  respond(conn, 200, "text/html; charset=utf-8", page)
}

///|
async fn admin_users_page(
  conn : @http.ServerConnection,
  meta : @lib.JsonMeta,
  notice : String,
) -> Unit {
  let rows = StringBuilder()
  for user in meta.list_users() {
    rows.write_string(
      "<tr><form method=\"post\" action=\"/admin/users/update\"><td>" +
      user.username +
      "<input type=\"hidden\" name=\"id\" value=\"",
    )
    rows.write_string(user.id.to_string())
    rows.write_string("\"></td><td><select name=\"role\">")
    for role in ["read", "write", "none", "admin"] {
      let label = if role == "read" {
        "只读"
      } else if role == "write" {
        "可编辑"
      } else if role == "none" {
        "禁止访问"
      } else {
        "管理员"
      }
      rows.write_string("<option value=\"" + role + "\"")
      if user.role == role {
        rows.write_string(" selected")
      }
      rows.write_string(">" + label + "</option>")
    }
    rows.write_string("</select></td><td><input name=\"write_prefix\" value=\"")
    rows.write_string(user.write_prefix)
    rows.write_string(
      "\" placeholder=\"例如 guide\"></td><td><select name=\"enabled\"><option value=\"true\"",
    )
    if user.enabled {
      rows.write_string(" selected")
    }
    rows.write_string(">启用</option><option value=\"false\"")
    if !user.enabled {
      rows.write_string(" selected")
    }
    rows.write_string(
      ">禁用</option></select></td><td><button>保存</button></td></form><td>",
    )
    if user.role != "admin" {
      rows.write_string(
        "<form method=\"post\" action=\"/admin/users/password\"><input type=\"hidden\" name=\"id\" value=\"",
      )
      rows.write_string(user.id.to_string())
      rows.write_string(
        "\"><input name=\"password\" type=\"password\" minlength=\"12\" placeholder=\"新密码\" required><button>重置密码</button></form>",
      )
    }
    rows.write_string("</td></tr>")
  }
  let page = "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>用户详情</title><link rel=\"stylesheet\" href=\"/site.css\"></head><body><p><a href=\"/admin/keys#users\">返回后台概览</a></p><h1>全部用户</h1><p class=\"notice\">" +
    notice +
    "</p><table class=\"user-table\"><thead><tr><th>账号</th><th>权限</th><th>可写范围</th><th>状态</th><th></th><th>密码</th></tr></thead><tbody>" +
    rows.to_string() +
    "</tbody></table></body></html>"
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
async fn site_product_name(meta : @lib.JsonMeta) -> String {
  match meta.get_config("site.title") {
    Some(value) if !value.is_empty() => value
    _ => "mbt-mdwiki"
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
fn session_subject(
  request : @http.Request,
  login_state : LoginState,
) -> String? {
  match extract_cookie(request, "mbt_auth") {
    Some(token) if !login_state.revoked.contains(token) =>
      match login_state.active_tokens.get(token) {
        Some(subject) => Some(subject)
        None => @lib.verify_jwt(login_state.secret, token)
      }
    _ => None
  }
}

///|
fn session_authenticated(
  request : @http.Request,
  admin_session : AdminSession,
  login_state : LoginState,
) -> Bool {
  match session_subject(request, login_state) {
    Some(subject) if subject == "admin" => true
    Some(subject) =>
      match login_state.subjects.get(subject) {
        Some(user) => user.enabled && user.role != "none"
        None => false
      }
    None => admin_authenticated(request, admin_session)
  }
}

///|
fn session_is_admin(
  request : @http.Request,
  admin_session : AdminSession,
  login_state : LoginState,
) -> Bool {
  match session_subject(request, login_state) {
    Some(subject) if subject == "admin" => true
    Some(subject) =>
      match login_state.subjects.get(subject) {
        Some(user) => user.enabled && user.role == "admin"
        None => false
      }
    None => admin_authenticated(request, admin_session)
  }
}

///|
fn session_can_edit(request : @http.Request, login_state : LoginState) -> Bool {
  match session_subject(request, login_state) {
    Some(subject) if subject == "admin" => true
    Some(subject) =>
      match login_state.subjects.get(subject) {
        Some(user) =>
          user.enabled && (user.role == "write" || user.role == "admin")
        None => false
      }
    None => false
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
      let product_name = site_product_name(meta_store)
      let tags = if meta.tags.is_empty() {
        ""
      } else {
        let chips = meta.tags
          .replace_all(old=", ", new=",")
          .split(",")
          .map(fn(tag) {
            "<span class=\"tag\">" + tag.trim().to_owned() + "</span>"
          })
          .join("")
        "<div class=\"tags\"><small>标签</small>" + chips + "</div>"
      }
      let page_title = meta.title + " - " + product_name
      let tree = if site_show_tree(meta_store) {
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
      let edit_link = if can_edit {
        "<a href=\"/edit\">进入编辑器</a>"
      } else {
        ""
      }
      let breadcrumb = if slug == "index" {
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
              "<strong>" + meta.title + "</strong>"
            } else {
              "<a href=\"" + href + "\">" + part + "</a>"
            })
          if i < parts.length() - 1 {
            links = links + "<span>/</span>"
          }
        }
        links
      }
      let page = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" +
        page_title +
        "</title><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"reading-shell\"><div class=\"topbar\"><a href=\"/\">" +
        product_name +
        "</a><span class=\"account\">" +
        (if can_edit {
          "<a href=\"/logout\">退出登录</a>"
        } else {
          "<a href=\"/login\">登录</a>"
        }) +
        "</span>" +
        "<span class=\"edit\">" +
        edit_link +
        "</span></div>" +
        "<div class=\"breadcrumbs\">" +
        breadcrumb +
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
async fn serve_llms(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  prefixes : String,
) -> Unit {
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
async fn list_docs_with_prefix(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  prefix : String,
) -> Unit {
  let slugs = storage
    .list()
    .filter(fn(slug) { allowed_read_prefix(prefix, slug) })
  let items = slugs.map(fn(slug) { "\"" + slug + "\"" }).join(",")
  respond(conn, 200, "application/json", "{\"docs\":[" + items + "]}")
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
  read_prefix : String,
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
    if !allowed_read_prefix(read_prefix, slug) {
      continue
    }
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
