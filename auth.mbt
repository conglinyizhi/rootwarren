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
