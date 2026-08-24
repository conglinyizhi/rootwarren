///|
#warnings("-alert_experimental")
fn main {
  // rootwarren 为多页应用(MPA)：各页面服务端渲染完整 HTML + 内联 JS(登录/编辑/主题)，
  // 无需浏览器端 SPA 水合。此入口保留以产出构建产物，实际交互由各页面内联脚本承担。
  ()
}
