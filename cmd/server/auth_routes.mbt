// 认证相关路由：/api/auth/* 与 /sys/login 登录页。
// 同包内其他文件可调用本模块的 register_auth_routes 与 render_login_page。

///|
/// 解析登录请求体 username/password。提取不到返回空串。
fn parse_login(body : String) -> (String, String) {
  let json = @json.parse(body) catch { _ => return ("", "") }
  match json {
    Json::Object(map) =>
      (map_get_string(map, "username"), map_get_string(map, "password"))
    _ => ("", "")
  }
}

///|
/// 注册认证路由：POST /api/auth/login、POST /api/auth/logout、GET /api/auth/me。
fn register_auth_routes(
  ctx : @moonback.ModuleContext,
  meta : @lib.JsonMeta,
  auth : AuthState,
) -> Unit raise {
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
  ctx.get("/sys/login", (_req, res) => {
    let page = render_login_page(meta)
    res.send_html(@moonback.Html::raw(page))
  })
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
