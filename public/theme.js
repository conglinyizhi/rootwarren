/* rootwarren 主题初始化 + 持久化（浏览器端）
 * 1) 防闪烁：CSS 解析前按浏览器存储设定 <html data-theme>
 * 2) 点击持久化：监听 data-theme-apply 按钮的点击写 localStorage
 * 说明：本文件作为 <script src> 被真实加载执行（避免 rabbit 内联 script 不执行的问题）。 */
(function () {
  try {
    var t = localStorage.getItem('mbt-theme')
    if (t === 'light' || t === 'dark') {
      document.documentElement.dataset.theme = t
    }
  } catch (e) {}
})()

document.addEventListener(
  'click',
  function (e) {
    var b = e.target && e.target.closest ? e.target.closest('[data-theme-apply]') : null
    if (b) {
      var t = b.getAttribute('data-theme-apply')
      try {
        if (t === 'light' || t === 'dark') {
          document.documentElement.dataset.theme = t
          localStorage.setItem('mbt-theme', t)
        } else {
          delete document.documentElement.dataset.theme
          localStorage.removeItem('mbt-theme')
        }
      } catch (x) {}
    }
  },
  false,
)
