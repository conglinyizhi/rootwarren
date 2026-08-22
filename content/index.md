# mbt-mdwiki

一个由 MoonBit 驱动的、面向人类与大语言模型的 Markdown Wiki。

## 从这里开始

- [快速开始](guide/getting-started) 了解如何浏览和编辑文档。
- [客户端设计](guide/client-design) 了解 Web、TUI 或 Agent 客户端应如何接入。
- [访问控制](guide/access-control) 了解公开浏览、后台会话和 API 密钥的区别。

## 这个 Wiki 的原则

文档源文件保存在服务器的 `content/` 目录中。浏览器负责阅读，REST API 负责让客户端和 Agent 读取、搜索与修改文档。

没有登录时，公开站点只展示渲染后的文档；登录后台后，才可以从客户端进入编辑和创建流程。
