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
  let secret = @lib.generate_session_secret() catch { _ => "insecure-fallback-secret" }
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
        if token.is_empty() { None } else { Some(token) }
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
pub fn AuthState::authenticate(self : AuthState, req : @moonback.Request) -> String? {
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
        Some(user) => user.enabled && (user.role == "write" || user.role == "admin" || user.role == "superadmin")
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
        Some(user) => user.enabled && (user.role == "admin" || user.role == "superadmin")
        None => false
      }
    None => false
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
pub fn AuthState::register_user(self : AuthState, user : @lib.UserRecord) -> String? {
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


