///|
/// 元数据存储：纯文本 JSON 文件（`meta/config.json` + `meta/api_keys.json`）。
/// 不用 sqlite：减少依赖、文件可 git、可回退；单进程规模足够。
/// 写文件用「临时文件 + rename」保证原子性。
struct JsonMeta {
  dir : String
}

///|
/// 打开元数据目录（不存在则自动创建）
pub async fn JsonMeta::open(dir : String) -> JsonMeta {
  if !@fs.exists(dir) {
    @fs.mkdir(dir, recursive=true)
  }
  { dir, }
}

///|
fn JsonMeta::config_path(self : JsonMeta) -> String {
  self.dir + "/config.json"
}

///|
fn JsonMeta::api_keys_path(self : JsonMeta) -> String {
  self.dir + "/api_keys.json"
}

///|
async fn JsonMeta::load_config(self : JsonMeta) -> Map[String, String] {
  let path = self.config_path()
  guard @fs.exists(path) else { return {} }
  let content = @utf8.decode_lossy(@fs.read_file(path).binary()[:])
  let json = @json.parse(content) catch { _ => return {} }
  let result : Map[String, String] = Map([])
  if json is Object(obj) {
    for k, v in obj {
      if v is String(s) {
        result[k] = s
      }
    }
  }
  result
}

///|
async fn JsonMeta::save_config(
  self : JsonMeta,
  config : Map[String, String],
) -> Unit {
  let obj : Map[String, Json] = Map([])
  for k, v in config {
    obj[k] = Json::string(v)
  }
  let content = Json::object(obj).stringify(indent=2)
  let tmp = self.config_path() + ".tmp"
  @fs.write_file(tmp, content)
  @fs.rename(tmp, self.config_path(), replace=true)
}

///|
/// 读配置项，不存在返回 None
pub async fn JsonMeta::get_config(self : JsonMeta, key : String) -> String? {
  self.load_config().get(key)
}

///|
/// 写配置项
pub async fn JsonMeta::set_config(
  self : JsonMeta,
  key : String,
  value : String,
) -> Unit {
  let config = self.load_config()
  config[key] = value
  self.save_config(config)
}

///|
pub struct ApiKeyRecord {
  id : Int
  name : String
  key_hash : String
  scopes : String
  mut enabled : Bool
  created_at : String
}

///|
pub struct ApiKeyInfo {
  id : Int
  name : String
  scopes : String
  enabled : Bool
  created_at : String
}

///|
fn json_str(o : Map[String, Json], key : String) -> String {
  match o.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn json_int(o : Map[String, Json], key : String) -> Int {
  match o.get(key) {
    Some(Number(n, repr=_)) => n.to_int()
    _ => 0
  }
}

///|
fn json_bool(o : Map[String, Json], key : String) -> Bool {
  match o.get(key) {
    Some(True) => true
    _ => false
  }
}

///|
async fn JsonMeta::load_api_keys(self : JsonMeta) -> Array[ApiKeyRecord] {
  let path = self.api_keys_path()
  guard @fs.exists(path) else { return [] }
  let content = @utf8.decode_lossy(@fs.read_file(path).binary()[:])
  let json = @json.parse(content) catch { _ => return [] }
  let result : Array[ApiKeyRecord] = []
  if json is Array(items) {
    for item in items {
      if item is Object(o) {
        result.push({
          id: json_int(o, "id"),
          name: json_str(o, "name"),
          key_hash: json_str(o, "key_hash"),
          scopes: json_str(o, "scopes"),
          enabled: json_bool(o, "enabled"),
          created_at: json_str(o, "created_at"),
        })
      }
    }
  }
  result
}

///|
async fn JsonMeta::save_api_keys(
  self : JsonMeta,
  keys : Array[ApiKeyRecord],
) -> Unit {
  let arr : Array[Json] = []
  for k in keys {
    let obj : Map[String, Json] = {
      "id": Json::number(k.id.to_double()),
      "name": Json::string(k.name),
      "key_hash": Json::string(k.key_hash),
      "scopes": Json::string(k.scopes),
      "enabled": Json::boolean(k.enabled),
      "created_at": Json::string(k.created_at),
    }
    arr.push(Json::object(obj))
  }
  let content = Json::array(arr).stringify(indent=2)
  let tmp = self.api_keys_path() + ".tmp"
  @fs.write_file(tmp, content)
  @fs.rename(tmp, self.api_keys_path(), replace=true)
}

///|
/// 创建 API key：返回明文 key（仅此一次，文件里只存哈希）
pub async fn JsonMeta::create_api_key(
  self : JsonMeta,
  name : String,
  scopes : String,
) -> String {
  let keys = self.load_api_keys()
  let next_id = keys.fold(init=0, fn(acc, k) {
      if k.id > acc {
        k.id
      } else {
        acc
      }
    }) +
    1
  let plain = generate_api_key()
  let record = {
    id: next_id,
    name,
    key_hash: hash_api_key(plain),
    scopes,
    enabled: true,
    created_at: "",
  }
  keys.push(record)
  self.save_api_keys(keys)
  plain
}

///|
/// 校验 API key：key 有效且启用时返回 scopes，否则 None
pub async fn JsonMeta::verify_api_key(self : JsonMeta, key : String) -> String? {
  let hash = hash_api_key(key)
  for record in self.load_api_keys() {
    if record.key_hash == hash && record.enabled {
      return Some(record.scopes)
    }
  }
  None
}

///|
/// 列出全部 API key（不含哈希）
pub async fn JsonMeta::list_api_keys(self : JsonMeta) -> Array[ApiKeyInfo] {
  let result : Array[ApiKeyInfo] = []
  for r in self.load_api_keys() {
    result.push({
      id: r.id,
      name: r.name,
      scopes: r.scopes,
      enabled: r.enabled,
      created_at: r.created_at,
    })
  }
  result
}

///|
/// 吊销 API key（软删除：enabled = false）
pub async fn JsonMeta::revoke_api_key(self : JsonMeta, id : Int) -> Unit {
  let keys = self.load_api_keys()
  for i in 0..<keys.length() {
    if keys[i].id == id {
      keys[i].enabled = false
    }
  }
  self.save_api_keys(keys)
}
