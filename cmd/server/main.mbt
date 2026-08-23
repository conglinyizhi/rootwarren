///|
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let api = @moonback.Module(ctx => {
    // 静态资源：rabbit page_service 会引用 /styles.css 与 /index.js
    ctx.add_middleware(@static.new(root="public"))
    ctx.get("/health", (_req, res) => {
      res.send_json({ "status": "ok" })
    })
    ctx.get("/api/v1/docs", (_req, res) => {
      let slugs = storage.list()
      let items = slugs.map(fn(slug) { Json::string(slug) })
      res.send_json({ "docs": Json::array(items) })
    })
    ctx.get("/api/v1/docs/*slug", (req, res) => {
      let slug = match req.params.get("slug") {
        Some(s) => s.to_owned()
        None => {
          res.send_text("missing slug", status=400)
          return
        }
      }
      match storage.read(slug) {
        Some(raw) => {
          let html = @lib.render_doc_html(raw)
          res.send_json({ "slug": Json::string(slug), "html": Json::string(html) })
        }
        None => {
          res.send_json({ "error": Json::string("not found") }, status=404)
        }
      }
    })
    ctx.add_route(@http.RequestMethod::Put, "/api/v1/docs/*slug", (req, res) => {
      let slug = match req.params.get("slug") {
        Some(s) => s.to_owned()
        None => {
          res.send_text("missing slug", status=400)
          return
        }
      }
      if !@lib.valid_slug(slug) {
        res.send_text("invalid slug", status=400)
        return
      }
      let content = req.body.text()
      let success = try {
        storage.write(slug, content)
        true
      } catch {
        _ => false
      }
      if success {
        res.send_json({ "ok": Json::boolean(true) })
      } else {
        res.send_text("invalid slug", status=400)
      }
    })
    ctx.add_route(@http.RequestMethod::Delete, "/api/v1/docs/*slug", (req, res) => {
      let slug = match req.params.get("slug") {
        Some(s) => s.to_owned()
        None => {
          res.send_text("missing slug", status=400)
          return
        }
      }
      if !@lib.valid_slug(slug) {
        res.send_text("invalid slug", status=400)
        return
      }
      storage.delete(slug)
      res.send_json({ "ok": Json::boolean(true) })
    })
  })

  let server = @rserver.Server(api=api, port=8080, component=@app.app)
  server.run_forever()
}
