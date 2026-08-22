///|
async fn main {
  let storage = @lib.LocalStorage::new("content")
  let server = @http.Server(@socket.Addr::parse("0.0.0.0:8001"))
  server.run_forever() <| ((request, _body, conn) => {
    match (request.meth, request.path) {
      (Get, "/health") => {
        conn.send_response(200, "OK", extra_headers={ "Content-Type": "text/plain" })
        conn.write_string("ok")
        conn.end_response()
      }
      (Get, "/docs") => {
        let slugs = @lib.Storage::list(storage)
        conn.send_response(200, "OK", extra_headers={ "Content-Type": "text/plain" })
        for slug in slugs {
          conn.write_string(slug + "\n")
        }
        conn.end_response()
      }
      _ => {
        conn.send_response(404, "Not Found", extra_headers={ "Content-Type": "text/plain" })
        conn.write_string("Not Found")
        conn.end_response()
      }
    }
  })
}
