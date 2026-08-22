///|
/// 内容存储抽象：MVP 只实现本地文件，后续可加内存盘（测试）/对象存储。
pub trait Storage {
  /// 读原始 Markdown，不存在返回 `None`
  async fn read(Self, slug : String) -> String?

  /// 写（创建或覆盖）
  async fn write(Self, slug : String, content : String) -> Unit

  /// 删除，不存在时静默成功
  async fn delete(Self, slug : String) -> Unit

  /// 列出全部 slug
  async fn list(Self) -> Array[String]
}
