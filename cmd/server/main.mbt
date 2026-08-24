///|
#warnings("-alert_experimental")
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let meta = @lib.JsonMeta::open("meta")
  // 先加载 .env（shell 环境变量优先），再读取配置
  let env = @env.get_env_vars()
  load_dotenv(env)
  let port = cli_port(env)
  let admin_user = match meta.get_config("auth.admin_username") {
    Some(v) if !v.is_empty() => v
    _ => "operator"
  }
  let admin_hash = match meta.get_config("auth.admin_key_hash") {
    Some(v) => v
    None =>
      match env.get("ADMIN_TOKEN") {
        Some(v) if !v.is_empty() => @lib.hash_api_key(v)
        _ => ""
      }
  }
  let auth = AuthState::new(admin_user, admin_hash)
  let api = @moonback.Module(ctx => {
    // 静态资源：rabbit page_service 会引用 /styles.css 与 /index.js
    ctx.add_middleware(@static.new(root="public"))
    // 认证（/api/auth/* 与 /sys/login）
    register_auth_routes(ctx, meta, auth)
    // 后台管理（/api/admin/*）
    register_admin_routes(ctx, meta, auth)
    // 站点级（/health、/llms.txt、/feed、/api/v1/config）
    register_site_routes(ctx, storage, meta)
    // 文档路由（/d、/posts、/category、/api/v1/docs、/api/v1/backlinks）
    register_docs_routes(ctx, storage, meta, auth)
  })

  let server = @rserver.Server(api~, port~, component=@app.app)
  server.run_forever()
}

///|
/// 从 JSON 请求体解析 username / password。提取不到返回空串。
async fn load_dotenv(env : Map[String, String]) -> Unit {
  if !@fs.exists(".env") {
    return
  }
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
/// 解析命令行 `--port` 参数（若提供则覆盖环境变量 PORT）。
fn cli_port(env : Map[String, String]) -> UInt16 {
  let args = @env.args()
  let mut found : String = ""
  let mut i = 0
  while i < args.length() {
    if args[i] == "--port" && i + 1 < args.length() {
      found = args[i + 1]
    }
    i += 1
  }
  match found {
    "" => parse_port(env)
    v => @string.parse_uint(v).to_uint16() catch { _ => 8080 }
  }
}

///|
/// 读取监听端口：优先环境变量 PORT，默认 8080。
fn parse_port(env : Map[String, String]) -> UInt16 {
  match env.get("PORT") {
    Some(v) => @string.parse_uint(v).to_uint16() catch { _ => 8080 }
    None => 8080
  }
}

