///|
/// 本地文件系统实现：文档映射到 `root/slug.md`。
struct LocalStorage {
  root : String
}

///|
pub fn LocalStorage::new(root : String) -> LocalStorage {
  { root, }
}

///|
fn LocalStorage::path_for(self : LocalStorage, slug : String) -> String {
  self.root + "/" + slug + ".md"
}

///|
/// slug 路径安全校验：只允许字母数字、`-`、`_`、`/`，
/// 禁止 `..`/`.` 段逃逸和绝对路径。
pub fn valid_slug(slug : String) -> Bool {
  if slug.length() == 0 || slug[0] == '/' {
    return false
  }
  for part in slug.split("/") {
    if part == ".." || part == "." || part.length() == 0 {
      return false
    }
    for c in part {
      if !((c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-' ||
        c == '_') {
        return false
      }
    }
  }
  true
}

///|
pub extend LocalStorage with Storage::{read, write, delete, list}

///|
pub impl Storage for LocalStorage with fn read(self, slug : String) -> String? {
  if !valid_slug(slug) {
    return None
  }
  let path = self.path_for(slug)
  guard @fs.exists(path) else { return None }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let bytes = file.read_exactly(file.size().to_int())
  Some(@utf8.decode_lossy(bytes[:]))
}

///|
pub impl Storage for LocalStorage with fn write(
  self,
  slug : String,
  content : String,
) -> Unit {
  if !valid_slug(slug) {
    raise StorageError::InvalidSlug(slug)
  }
  let path = self.path_for(slug)
  let parent = match path.rev_find("/") {
    Some(i) => path[0:i + 1]
    None => ""
  }
  if parent.length() > 0 && !@fs.exists(parent) {
    @fs.mkdir(parent, recursive=true)
  }
  @fs.write_file(path, content)
}

///|
pub impl Storage for LocalStorage with fn delete(self, slug : String) -> Unit {
  if !valid_slug(slug) {
    return
  }
  let path = self.path_for(slug)
  guard @fs.exists(path) else { return }
  @fs.remove(path)
}

///|
pub impl Storage for LocalStorage with fn list(self) -> Array[String] {
  let slugs : Array[String] = []
  @fs.walk(self.root, (dir, entries) => {
    let rel = dir[self.root.length():]
    let dir_slug = (if rel.has_prefix("/") { rel[1:] } else { rel }).to_owned()
    for entry in entries {
      if entry.has_suffix(".md") {
        let name = entry[0:entry.length() - 3].to_owned()
        let slug = if dir_slug.length() == 0 {
          name
        } else {
          dir_slug + "/" + name
        }
        slugs.push(slug)
      }
    }
  })
  slugs
}

///|
/// 存储层错误
pub(all) suberror StorageError {
  InvalidSlug(String)
}
