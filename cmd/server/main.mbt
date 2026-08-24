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
    // 首页：用 home_page 组件 SSR（服务端渲染 index 文档 + 文档列表，便于 SEO/Agent 直接读）
    ctx.get("/", (req, res) => {
      let authed = auth.authenticate(req) is Some(_)
      let input = build_home_input(storage, meta, authed)
      let page = @rabbita.new(fn() { @app.home_page(input = input) })
      let html = page.render(url = "http://127.0.0.1/", timeout = 5000)
      res.send_html(@moonback.Html::raw(html))
    })
    // 认证（/api/auth/* 与 /sys/login）
    register_auth_routes(ctx, meta, auth)
    // 后台管理（/api/admin/*）
    register_admin_routes(ctx, meta, auth)
    // 站点级（/health、/llms.txt、/feed、/api/v1/config）
    register_site_routes(ctx, storage, meta)
    // 文档路由（/d、/posts、/category、/api/v1/docs、/api/v1/backlinks）
    register_docs_routes(ctx, storage, meta, auth)
    // 兜底：未匹配路径 → styled 404 页（避免浏览器赤裸的 404 文本）
    ctx.get("/*path", (_req, res) => {
      let page = render_not_found_page(meta)
      res.send_html(@moonback.Html::raw(page), status=404)
    })
  })

  let app = @moonback.App(api)
  let listener = @moonback.listen(reuse_addr=true, port=port)
  println("Server is running on http://127.0.0.1:\{port}")
  app.serve(listener)
}

///|
/// 渲染 styled 404 页（复用站点主题骨架，避免浏览器赤裸 404 文本）。
async fn render_not_found_page(meta : @lib.JsonMeta) -> String {
  let product_name = site_product_name(meta)
  "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>404 - " +
  product_name +
  "</title><script src=\"/theme.js\"></script><link rel=\"stylesheet\" href=\"/site.css\"></head><body><main class=\"reading-shell\"><div class=\"topbar\"><a href=\"/\">" +
  product_name +
  "</a></div><div class=\"not-found\"><h1>404</h1><p>页面不存在或已被移除。</p><p><a href=\"/\">返回文档站首页</a></p></div></main></body></html>"
}

///|
/// 构造首页输入：读 index 文档正文(渲染为 html) + 文档列表。
async fn build_home_input(
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
  authed : Bool,
) -> @app.HomeInput {
  // 顶栏站名用站点配置 title(与阅读/404 一致)；正文用 index 文档自身 title
  let site_title = site_product_name(meta)
  let doc_html = match storage.read("index") {
    Some(raw) => @lib.render_doc_html(raw, "index")
    None => "<p>暂无首页文档</p>"
  }
  let doc_list = storage.list()
  @app.home_input(site_title, doc_html, doc_list, authed)
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
