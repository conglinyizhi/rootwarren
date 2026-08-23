// 认证状态与工具（复用根库 auth/meta_store，不重写安全边界）。
// moonback handler 是闭包，直接捕获本模块的 AuthState 共享状态。

///|
/// 后台管理员会话的验证 provider（由根库 AdminTokenProvider 提供）。
/// 额外保存当前管理员用户名与 admin provider。
pub struct AuthState {
  secret : String
  provider : @lib.AdminTokenProvider
  revoked : Map[String, Bool]
  subjects : Map[String, @lib.UserRecord]
  active_tokens : Map[String, String]
}

///|
pub fn AuthState::new(
  admin_username : String,
  admin_key_hash : String,
) -> AuthState {
  let secret = @lib.generate_session_secret() catch {
    _ => "insecure-fallback-secret"
  }
  {
    secret,
    provider: @lib.AdminTokenProvider::from_hash(admin_username, admin_key_hash),
    revoked: Map([]),
    subjects: Map([]),
    active_tokens: Map([]),
  }
}

///|
/// 从 Authorization header 或 Cookie 提取 token。
pub fn request_token(req : @moonback.Request) -> String? {
  match req.headers.get("Authorization") {
    Some(raw) => {
      let raw = raw.to_owned()
      if raw.has_prefix("Bearer ") {
        let token = raw["Bearer ".length():].to_owned()
        if token.is_empty() {
          None
        } else {
          Some(token)
        }
      } else {
        None
      }
    }
    None =>
      match req.cookie().get("mbt_auth") {
        Some(c) => if c.is_empty() { None } else { Some(c) }
        None => None
      }
  }
}

///|
/// 校验 token：有效且未撤销时返回 subject。
pub fn AuthState::subject_for(self : AuthState, token : String) -> String? {
  if self.revoked.contains(token) {
    return None
  }
  match self.active_tokens.get(token) {
    Some(subject) => Some(subject)
    None => @lib.verify_jwt(self.secret, token)
  }
}

///|
/// 已登录且非撤销的 subject（用于权限判断）。
pub fn AuthState::authenticate(
  self : AuthState,
  req : @moonback.Request,
) -> String? {
  match request_token(req) {
    Some(token) => self.subject_for(token)
    None => None
  }
}

///|
/// 当前 user 是否可编辑（admin/superadmin/write）。
pub fn AuthState::can_edit(self : AuthState, req : @moonback.Request) -> Bool {
  match self.authenticate(req) {
    Some(subject) if subject == "admin" => true
    Some(subject) =>
      match self.subjects.get(subject) {
        Some(user) =>
          user.enabled &&
          (
            user.role == "write" ||
            user.role == "admin" ||
            user.role == "superadmin"
          )
        None => false
      }
    None => false
  }
}

///|
pub fn AuthState::is_admin(self : AuthState, req : @moonback.Request) -> Bool {
  match self.authenticate(req) {
    Some(subject) if subject == "admin" => true
    Some(subject) =>
      match self.subjects.get(subject) {
        Some(user) =>
          user.enabled && (user.role == "admin" || user.role == "superadmin")
        None => false
      }
    None => false
  }
}

///|
/// 当前请求用户的角色（内置 admin 视为 superadmin；未登录为 none）。
pub fn AuthState::session_role(
  self : AuthState,
  req : @moonback.Request,
) -> String {
  match self.authenticate(req) {
    Some(subject) if subject == "admin" => "superadmin"
    Some(subject) =>
      match self.subjects.get(subject) {
        Some(user) => user.role
        None => "none"
      }
    None => "none"
  }
}

///|
/// actor 能否管理 target 角色：superadmin 可管所有，admin 不能管 superadmin。
pub fn can_manage_role(actor : String, target : String) -> Bool {
  actor == "superadmin" || (actor == "admin" && target != "superadmin")
}

///|
pub fn valid_user_role(value : String) -> Bool {
  value == "superadmin" ||
  value == "admin" ||
  value == "none" ||
  value == "read" ||
  value == "write"
}

///|
/// 文档 API 的权限与范围。
pub struct DocsPerm {
  scopes : String
  read_prefix : String
  write_prefix : String
}

///|
/// 计算请求的文档权限（scope + 读/写前缀），复用根库 verify_api_key/find_user_by_id。
/// 优先 Bearer API key（含绑定用户交集），否则 cookie session。
pub async fn AuthState::docs_auth(
  self : AuthState,
  meta : @lib.JsonMeta,
  req : @moonback.Request,
) -> DocsPerm {
  // 1. Bearer API key
  if request_token(req) is Some(key) {
    if key.has_prefix("mk_") {
      match meta.verify_api_key(key) {
        Some(record) => {
          let mut scopes = record.scopes
          let read_prefix = record.read_prefix
          let mut write_prefix = record.write_prefix
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
          return { scopes, read_prefix, write_prefix }
        }
        None => return { scopes: "", read_prefix: "", write_prefix: "" }
      }
    }
  }
  // 2. cookie session（JWT）
  match self.authenticate(req) {
    Some(subject) if subject == "admin" =>
      return { scopes: "read,write", read_prefix: "", write_prefix: "" }
    Some(subject) =>
      match self.subjects.get(subject) {
        Some(user) => {
          let scopes = if user.role == "write" ||
            user.role == "admin" ||
            user.role == "superadmin" {
            "read,write"
          } else {
            user.role
          }
          return { scopes, read_prefix: "", write_prefix: user.write_prefix }
        }
        None => ()
      }
    None => ()
  }
  // 3. 公开站点：匿名可读（site.public=true）
  if site_is_public(meta) {
    return { scopes: "read", read_prefix: "", write_prefix: "" }
  }
  { scopes: "", read_prefix: "", write_prefix: "" }
}

///|
pub fn can_write(scopes : String) -> Bool {
  scopes.split(",").any(fn(s) { s == "write" })
}

///|
pub fn can_read(scopes : String) -> Bool {
  scopes.split(",").any(fn(s) { s == "read" || s == "write" })
}

///|
pub fn allowed_read_prefix(prefix : String, slug : String) -> Bool {
  prefix.is_empty() || slug == prefix || slug.has_prefix(prefix + "/")
}

///|
pub fn allowed_write_prefix(prefix : String, slug : String) -> Bool {
  prefix.is_empty() || slug == prefix || slug.has_prefix(prefix + "/")
}

///|
/// 求两个前缀的交集（取更具体的一个；无交集返回空）。
fn intersect_prefix(a : String, b : String) -> String {
  if a.is_empty() {
    b
  } else if b.is_empty() {
    a
  } else if a == b || a.has_prefix(b + "/") {
    a
  } else if b.has_prefix(a + "/") {
    b
  } else {
    ""
  }
}

///|
/// 管理员登录：验证 provider，成功则签发 token。返回 token?
pub fn AuthState::admin_login(
  self : AuthState,
  username : String,
  password : String,
) -> String? {
  if self.provider.verify(username, password) {
    let token = @lib.issue_jwt(self.secret, "admin")
    self.active_tokens[token] = "admin"
    return Some(token)
  }
  None
}

///|
/// 登记一个已验证的普通用户并签发 token。返回 token?
pub fn AuthState::register_user(
  self : AuthState,
  user : @lib.UserRecord,
) -> String? {
  if !user.enabled || user.role == "none" {
    return None
  }
  let token = @lib.issue_jwt(self.secret, user.username)
  self.active_tokens[token] = user.username
  self.subjects[user.username] = user
  Some(token)
}

///|
/// 登出：撤销 token。
pub fn AuthState::logout(self : AuthState, req : @moonback.Request) -> Unit {
  match request_token(req) {
    Some(token) => {
      self.revoked[token] = true
      self.active_tokens.remove(token)
    }
    None => ()
  }
}
