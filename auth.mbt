///|
/// API key 工具：生成、哈希（sha256）、校验。
/// 库中只存哈希，明文 key 仅在创建时返回一次。

///|
/// 计算 API key 的 sha256 哈希（hex 编码）
pub fn hash_api_key(key : String) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(key)))
}

///|
/// 生成随机 API key：`mk_` 前缀 + 32 位 base62 字符
pub fn generate_api_key() -> String {
  let rand = @random.Rand::chacha8()
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  let sb = StringBuilder()
  for _i in 0..<32 {
    sb.write_char(chars.get_char(rand.int(limit=chars.length())).unwrap())
  }
  "mk_" + sb.to_string()
}
