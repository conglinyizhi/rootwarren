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
fn JsonMeta::users_path(self : JsonMeta) -> String {
  self.dir + "/users.json"
}

///|
fn JsonMeta::categories_path(self : JsonMeta) -> String {
  self.dir + "/categories.json"
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
  user_id : Int
  read_prefix : String
  write_prefix : String
  mut enabled : Bool
  created_at : String
}

///|
pub struct ApiKeyInfo {
  id : Int
  name : String
  scopes : String
  user_id : Int
  read_prefix : String
  write_prefix : String
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
          user_id: json_int(o, "user_id"),
          read_prefix: json_str(o, "read_prefix"),
          write_prefix: json_str(o, "write_prefix"),
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
      "user_id": Json::number(k.user_id.to_double()),
      "read_prefix": Json::string(k.read_prefix),
      "write_prefix": Json::string(k.write_prefix),
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
pub struct UserRecord {
  id : Int
  username : String
  mut password_hash : String
  mut role : String
  mut enabled : Bool
  mut write_prefix : String
}

///|
pub struct CategoryRecord {
  id : Int
  name : String
  slug : String
  parent_id : Int
  description : String
}

///|
async fn JsonMeta::load_categories(self : JsonMeta) -> Array[CategoryRecord] {
  let path = self.categories_path()
  guard @fs.exists(path) else { return [] }
  let content = @utf8.decode_lossy(@fs.read_file(path).binary()[:])
  let json = @json.parse(content) catch { _ => return [] }
  let result : Array[CategoryRecord] = []
  if json is Array(items) {
    for item in items {
      if item is Object(o) {
        result.push({
          id: json_int(o, "id"),
          name: json_str(o, "name"),
          slug: json_str(o, "slug"),
          parent_id: json_int(o, "parent_id"),
          description: json_str(o, "description"),
        })
      }
    }
  }
  result
}

///|
async fn JsonMeta::save_categories(self : JsonMeta, categories : Array[CategoryRecord]) -> Unit {
  let items : Array[Json] = []
  for c in categories {
    items.push(Json::object({
      "id": Json::number(c.id.to_double()),
      "name": Json::string(c.name),
      "slug": Json::string(c.slug),
      "parent_id": Json::number(c.parent_id.to_double()),
      "description": Json::string(c.description),
    }))
  }
  let tmp = self.categories_path() + ".tmp"
  @fs.write_file(tmp, Json::array(items).stringify(indent=2))
  @fs.rename(tmp, self.categories_path(), replace=true)
}

///|
pub async fn JsonMeta::list_categories(self : JsonMeta) -> Array[CategoryRecord] {
  self.load_categories()
}

///|
pub async fn JsonMeta::create_category(
  self : JsonMeta,
  name : String,
  slug : String,
  parent_id : Int,
  description : String,
) -> Bool {
  let categories = self.load_categories()
  for c in categories {
    if c.slug == slug {
      return false
    }
  }
  let next_id = categories.fold(init=0, fn(max_id, c) {
    if c.id > max_id { c.id } else { max_id }
  }) +
    1
  categories.push({ id: next_id, name, slug, parent_id, description })
  self.save_categories(categories)
  true
}

///|
async fn JsonMeta::load_users(self : JsonMeta) -> Array[UserRecord] {
  let path = self.users_path()
  guard @fs.exists(path) else { return [] }
  let content = @utf8.decode_lossy(@fs.read_file(path).binary()[:])
  let json = @json.parse(content) catch { _ => return [] }
  let users : Array[UserRecord] = []
  if json is Array(items) {
    for item in items {
      if item is Object(o) {
        users.push({
          id: json_int(o, "id"),
          username: json_str(o, "username"),
          password_hash: json_str(o, "password_hash"),
          role: json_str(o, "role"),
          enabled: json_bool(o, "enabled"),
          write_prefix: json_str(o, "write_prefix"),
        })
      }
    }
  }
  users
}

///|
async fn JsonMeta::save_users(
  self : JsonMeta,
  users : Array[UserRecord],
) -> Unit {
  let items : Array[Json] = []
  for user in users {
    items.push(
      Json::object({
        "id": Json::number(user.id.to_double()),
        "username": Json::string(user.username),
        "password_hash": Json::string(user.password_hash),
        "role": Json::string(user.role),
        "enabled": Json::boolean(user.enabled),
        "write_prefix": Json::string(user.write_prefix),
      }),
    )
  }
  let tmp = self.users_path() + ".tmp"
  @fs.write_file(tmp, Json::array(items).stringify(indent=2))
  @fs.rename(tmp, self.users_path(), replace=true)
}

///|
pub async fn JsonMeta::find_user_by_id(
  self : JsonMeta,
  id : Int,
) -> UserRecord? {
  for user in self.load_users() {
    if user.id == id && user.enabled {
      return Some(user)
    }
  }
  None
}

///|
pub async fn JsonMeta::find_user(
  self : JsonMeta,
  username : String,
) -> UserRecord? {
  for user in self.load_users() {
    if user.username == username && user.enabled {
      return Some(user)
    }
  }
  None
}

///|
pub async fn JsonMeta::list_users(self : JsonMeta) -> Array[UserRecord] {
  self.load_users()
}

///|
pub async fn JsonMeta::create_user(
  self : JsonMeta,
  username : String,
  password : String,
  role : String,
  write_prefix : String,
) -> Bool {
  let users = self.load_users()
  for user in users {
    if user.username == username {
      return false
    }
  }
  let next_id = users.fold(init=0, fn(max_id, user) {
      if user.id > max_id {
        user.id
      } else {
        max_id
      }
    }) +
    1
  users.push({
    id: next_id,
    username,
    password_hash: hash_api_key(password),
    role,
    enabled: true,
    write_prefix,
  })
  self.save_users(users)
  true
}

///|
pub async fn JsonMeta::reset_user_password(
  self : JsonMeta,
  id : Int,
  password : String,
) -> Bool {
  let users = self.load_users()
  let mut found = false
  for i in 0..<users.length() {
    if users[i].id == id {
      users[i].password_hash = hash_api_key(password)
      found = true
    }
  }
  if found {
    self.save_users(users)
  }
  found
}

///|
pub async fn JsonMeta::update_user(
  self : JsonMeta,
  id : Int,
  role : String,
  write_prefix : String,
  enabled : Bool,
) -> Bool {
  let users = self.load_users()
  let mut found = false
  for i in 0..<users.length() {
    if users[i].id == id {
      users[i].role = role
      users[i].write_prefix = write_prefix
      users[i].enabled = enabled
      found = true
    }
  }
  if found {
    self.save_users(users)
  }
  found
}

///|
pub async fn JsonMeta::verify_user(
  self : JsonMeta,
  username : String,
  password : String,
) -> UserRecord? {
  let hash = hash_api_key(password)
  for user in self.load_users() {
    if user.username == username && user.enabled && user.password_hash == hash {
      return Some(user)
    }
  }
  None
}

///|
/// 创建 API key：返回明文 key（仅此一次，文件里只存哈希）
pub async fn JsonMeta::create_api_key(
  self : JsonMeta,
  name : String,
  scopes : String,
  user_id : Int,
  read_prefix : String,
  write_prefix : String,
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
    user_id,
    read_prefix,
    write_prefix,
    enabled: true,
    created_at: "",
  }
  keys.push(record)
  self.save_api_keys(keys)
  plain
}

///|
/// 校验 API key：有效时返回完整绑定记录。
pub async fn JsonMeta::verify_api_key(
  self : JsonMeta,
  key : String,
) -> ApiKeyRecord? {
  let hash = hash_api_key(key)
  for record in self.load_api_keys() {
    if record.key_hash == hash && record.enabled {
      return Some(record)
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
      user_id: r.user_id,
      read_prefix: r.read_prefix,
      write_prefix: r.write_prefix,
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
