///|
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let meta = @lib.JsonMeta::open("meta")
  let port = match @env.get_env_var("PORT") {
    Some(p) => p
    None => "8001"
  }
  let server = @http.Server(@socket.Addr::parse("0.0.0.0:" + port))
  server.run_forever() <| ((request, body, conn) => {
    handle(request, body, conn, storage, meta)
  })
}

///|
async fn respond(
  conn : @http.ServerConnection,
  code : Int,
  content_type : String,
  body : String,
) -> Unit {
  conn.send_response(code, "OK", extra_headers={ "Content-Type": content_type })
  conn.write_string(body)
  conn.end_response()
}

///|
async fn respond_error(conn : @http.ServerConnection, code : Int, msg : String) -> Unit {
  let body = "{\"error\":{\"code\":\"" + code.to_string() + "\",\"message\":\"" + msg + "\"}}"
  respond(conn, code, "application/json", body)
}

///|
async fn handle(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
) -> Unit {
  let path = request.path
  if request.meth is Get && path == "/health" {
    respond(conn, 200, "text/plain", "ok")
    return
  }
  if path.has_prefix("/api/v1/") {
    handle_api(request, body, conn, storage, meta)
    return
  }
  if request.meth is Get && path.has_prefix("/d/") {
    render_doc_page(request, conn, storage)
    return
  }
  respond(conn, 404, "text/plain", "Not Found")
}

///|
async fn handle_api(
  request : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  meta : @lib.JsonMeta,
) -> Unit {
  // 鉴权
  let scopes = match extract_bearer(request) {
    Some(key) => meta.verify_api_key(key)
    None => None
  }
  let scopes = match scopes {
    Some(s) => s
    None => {
      respond_error(conn, 401, "invalid or missing API key")
      return
    }
  }
  // 路由解析：/api/v1/<resource>[/<slug>][?query]
  let rest = request.path["/api/v1/".length():]
  let (rest_path, _query) = split_query(rest)
  let (resource, slug) = match rest_path.find("/") {
    Some(i) => (rest_path[:i].to_owned(), Some(rest_path[i + 1:].to_owned()))
    None => (rest_path, None)
  }
  match (request.meth, resource) {
    (Get, "docs") => {
      if !can_read(scopes) {
        respond_error(conn, 403, "read permission required")
        return
      }
      match slug {
        Some(s) => read_doc(request, conn, storage, s)
        None => list_docs(conn, storage)
      }
    }
    (Put, "docs") => {
      if !can_write(scopes) {
        respond_error(conn, 403, "write permission required")
        return
      }
      match slug {
        Some(s) => write_doc(body, conn, storage, s)
        None => respond_error(conn, 400, "slug required in path")
      }
    }
    (Delete, "docs") => {
      if !can_write(scopes) {
        respond_error(conn, 403, "write permission required")
        return
      }
      match slug {
        Some(s) => delete_doc(conn, storage, s)
        None => respond_error(conn, 400, "slug required in path")
      }
    }
    (Get, "search") => search_docs(request, conn, storage)
    (Get, "config") => {
      if !can_read(scopes) {
        respond_error(conn, 403, "read permission required")
        return
      }
      config_docs(conn, meta)
    }
    _ => respond_error(conn, 404, "endpoint not found")
  }
}

///|
fn can_read(scopes : String) -> Bool {
  for s in scopes.split(",") {
    if s == "read" || s == "write" {
      return true
    }
  }
  false
}

///|
fn can_write(scopes : String) -> Bool {
  for s in scopes.split(",") {
    if s == "write" {
      return true
    }
  }
  false
}

///|
fn extract_bearer(request : @http.Request) -> Option[String] {
  for k, v in request.headers {
    if k == "authorization" || k == "Authorization" {
      if v.has_prefix("Bearer ") {
        return Some(v["Bearer ".length():].to_owned())
      }
    }
  }
  None
}

///|
fn split_query(path : StringView) -> (String, String) {
  match path.find("?") {
    Some(i) => (path[:i].to_owned(), path[i + 1:].to_owned())
    None => (path.to_owned(), "")
  }
}

///|
fn query_param(query : String, name : String) -> Option[String] {
  for part in query.split("&") {
    if part.has_prefix(name + "=") {
      return Some(part[name.length() + 1:].to_owned())
    }
  }
  None
}

///|
async fn render_doc_page(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let (path, _) = split_query(request.path)
  let slug = path[3:].to_owned()
  match storage.read(slug) {
    Some(content) => {
      let html = @cmark_html.render(content, safe=true)
      let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>mbt-mdwiki</title></head><body>" + html + "</body></html>"
      respond(conn, 200, "text/html; charset=utf-8", page)
    }
    None => respond_error(conn, 404, "document not found")
  }
}

///|
async fn list_docs(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let slugs = storage.list()
  let items = slugs.map(fn(slug) { "\"" + slug + "\"" }).join(",")
  respond(conn, 200, "application/json", "{\"docs\":[" + items + "]}")
}

///|
async fn read_doc(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  slug : String,
) -> Unit {
  let (_, query) = split_query(request.path)
  match storage.read(slug) {
    Some(content) => {
      // D3 之前 format=html 先回 raw
      if query_param(query, "format") == Some("html") {
        respond(conn, 200, "text/html", content)
      } else {
        respond(conn, 200, "text/markdown; charset=utf-8", content)
      }
    }
    None => respond_error(conn, 404, "document not found")
  }
}

///|
async fn write_doc(
  body : &@io.Reader,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  slug : String,
) -> Unit {
  let content = @utf8.decode_lossy(body.read_all().binary()[:])
  let success = try {
    storage.write(slug, content)
    true
  } catch {
    _ => false
  }
  if success {
    respond(conn, 200, "application/json", "{\"ok\":true}")
  } else {
    respond_error(conn, 400, "invalid slug")
  }
}

///|
async fn delete_doc(
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
  slug : String,
) -> Unit {
  storage.delete(slug)
  respond(conn, 200, "application/json", "{\"ok\":true}")
}

///|
async fn search_docs(
  request : @http.Request,
  conn : @http.ServerConnection,
  storage : @lib.LocalStorage,
) -> Unit {
  let (_, query) = split_query(request.path)
  let q = match query_param(query, "q") {
    Some(x) => x
    None => {
      respond_error(conn, 400, "missing q parameter")
      return
    }
  }
  let hits : Array[String] = []
  for slug in storage.list() {
    match storage.read(slug) {
      Some(content) => {
        if slug.contains(q) || content.contains(q) {
          hits.push(slug)
        }
      }
      None => ()
    }
  }
  let items = hits.map(fn(s) { "\"" + s + "\"" }).join(",")
  respond(conn, 200, "application/json", "{\"results\":[" + items + "]}")
}

///|
async fn config_docs(
  conn : @http.ServerConnection,
  meta : @lib.JsonMeta,
) -> Unit {
  let title = match meta.get_config("site.title") {
    Some(t) => t
    None => "mbt-mdwiki"
  }
  let desc = match meta.get_config("site.description") {
    Some(d) => d
    None => ""
  }
  let body = "{\"site\":{\"title\":\"" + title + "\",\"description\":\"" + desc + "\"}}"
  respond(conn, 200, "application/json", body)
}
