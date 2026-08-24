// 共享的 JSON 解析辅助（同包内跨文件调用）。

///|
fn map_get_string(map : Map[String, Json], key : String) -> String {
  match map.get(key) {
    Some(Json::String(v)) => v
    _ => ""
  }
}

///|
fn js_int(map : Map[String, Json], key : String) -> Int {
  match map.get(key) {
    Some(Number(n, repr=_)) => n.to_int()
    _ => 0
  }
}

///|
fn js_bool(map : Map[String, Json], key : String) -> Bool {
  match map.get(key) {
    Some(True) => true
    _ => false
  }
}

///|
fn jv_string(json : Json, key : String) -> String {
  match json {
    Json::Object(map) => map_get_string(map, key)
    _ => ""
  }
}

///|
fn jv_int(json : Json, key : String) -> Int {
  match json {
    Json::Object(map) => js_int(map, key)
    _ => 0
  }
}

///|
fn jv_bool(json : Json, key : String) -> Bool {
  match json {
    Json::Object(map) => js_bool(map, key)
    _ => true
  }
}
