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
    ctx.get("/api/v1/docs/:slug", (req, res) => {
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
  })

  let server = @rserver.Server(api=api, port=8080, component=@app.app)
  server.run_forever()
}
