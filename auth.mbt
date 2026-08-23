///|
/// API key 工具：生成、哈希（sha256）、校验。
/// 库中只存哈希，明文 key 仅在创建时返回一次。

///|
/// 计算 API key 的 sha256 哈希（hex 编码）
pub fn hash_api_key(key : String) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(key)))
}

///|
pub(all) suberror EntropyUnavailable {
  EntropyUnavailable
}

///|
/// 生成随机 API key：`mk_` 前缀 + 平台熵源生成的 32 字节 hex。
/// 熵源不可用时失败，绝不回退到可预测的伪随机种子。
pub fn generate_api_key() -> String raise EntropyUnavailable {
  match @env.rand(32) {
    Some(bytes) => "mk_" + @crypto.bytes_to_hex_string(bytes)
    None => raise EntropyUnavailable::EntropyUnavailable
  }
}

///|
pub struct AdminTokenProvider {
  mut username : String
  mut key_hash : String
}

///|
pub fn AdminTokenProvider::new(
  username : String,
  token : String,
) -> AdminTokenProvider {
  {
    username,
    key_hash: if token.is_empty() {
      ""
    } else {
      hash_api_key(token)
    },
  }
}

///|
pub fn AdminTokenProvider::from_hash(
  username : String,
  key_hash : String,
) -> AdminTokenProvider {
  { username, key_hash }
}

///|
/// 当前本地账户 provider 的公开入口；未来 provider 可替换这一层。
pub fn AdminTokenProvider::verify(
  self : AdminTokenProvider,
  username : String,
  password : String,
) -> Bool {
  username == self.username &&
  !self.key_hash.is_empty() &&
  hash_api_key(password) == self.key_hash
}

///|
pub fn AdminTokenProvider::username(self : AdminTokenProvider) -> String {
  self.username
}

///|
pub fn AdminTokenProvider::configured(self : AdminTokenProvider) -> Bool {
  !self.key_hash.is_empty()
}

///|
pub fn AdminTokenProvider::set_credentials(
  self : AdminTokenProvider,
  username : String,
  key : String,
) -> Unit {
  self.username = username
  self.key_hash = hash_api_key(key)
}

///|
/// 生成仅用于当前进程的随机签名密钥。
pub fn generate_session_secret() -> String raise EntropyUnavailable {
  match @env.rand(32) {
    Some(bytes) => @crypto.bytes_to_hex_string(bytes)
    None => raise EntropyUnavailable::EntropyUnavailable
  }
}

///|
/// 使用 HS256 生成 JWT。token 的有效期由进程内 session registry 控制。
pub fn issue_jwt(secret : String, subject : String) -> String {
  let header = base64url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
  let payload = base64url("{\"sub\":\"" + subject + "\"}")
  let signing_input = header + "." + payload
  let signature = @crypto.hmac(
    @crypto.SHA256::new(),
    @utf8.encode(secret).view(),
    @utf8.encode(signing_input).view(),
  )
  signing_input + "." + base64url_bytes(signature)
}

///|
pub fn verify_jwt(secret : String, token : String) -> String? {
  let parts = token.split(".").to_array()
  if parts.length() != 3 {
    return None
  }
  let signing_input = parts[0].to_owned() + "." + parts[1].to_owned()
  let expected = @crypto.hmac(
    @crypto.SHA256::new(),
    @utf8.encode(secret).view(),
    @utf8.encode(signing_input).view(),
  )
  if base64url_bytes(expected) != parts[2].to_owned() {
    return None
  }
  let padded = parts[1].to_owned()
  let payload = @utf8.decode_lossy(
    @base64.decode_lossy(
      padded.replace_all(old="-", new="+").replace_all(old="_", new="/"),
    ),
  )
  match payload.find("\"sub\":\"") {
    Some(start) => {
      let value = payload[start + 8:]
      match value.find("\"") {
        Some(end) => Some(value[:end].to_owned())
        None => None
      }
    }
    None => None
  }
}

///|
fn base64url(value : String) -> String {
  @base64.encode(@utf8.encode(value).view(), padding=false)
  .replace_all(old="+", new="-")
  .replace_all(old="/", new="_")
}

///|
fn base64url_bytes(value : FixedArray[Byte]) -> String {
  let bytes = Bytes::from_array(value[:])
  @base64.encode(bytes.view(), padding=false)
  .replace_all(old="+", new="-")
  .replace_all(old="/", new="_")
}
