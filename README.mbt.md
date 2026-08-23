# mbt-mdwiki

一个基于 MoonBit 的 **full-rabbita 全栈 Markdown Wiki**。使用 `moonbit-community/rabbita` 完整版（SSR + 前端水合）+ `hackwaly/moonback`（后端 API）构建，前后端共享同一份组件包。

- `content/` 下的 Markdown 文档是数据源（slug 为相对路径去掉 `.md`）。
- 浏览器端是共享 full-rabbita 组件，由服务端 SSR 渲染、客户端水合。
- 提供受保护的 REST API 供 LLM 与其他客户端读写。

## 架构

```
app/            共享组件包（js+native+wasm，纯 UI，数据走 @http API）
cmd/browser/    前端水合入口  @rabbita.new(@app.app).hydrate()
cmd/server/     moonback 后端 + @rserver.Server(component=@app.app) SSR
  ├─ main.mbt   路由与 API
  └─ auth.mbt   认证状态（JWT + cookie session）
public/         静态资源（index.js 由 warren 生成，勿提交）
```

- 用户/文档/配置存在 `meta/`（gitignored），密钥与密码只存哈希。
- 认证用 HttpOnly cookie session（登录后浏览器自动携带，写接口无需手动带 header）。

## 开发

本机 MoonBit nightly 的 native archiver 探测有误，需 `MOON_CC=clang`（Makefile 已导出）。

```sh
make check            # 类型检查全部 target
cp .env.example .env  # 编辑 ADMIN_TOKEN
make dev              # 起 warren 全栈 dev server（SSR + 水合 + 热更新，端口 4300）
```

访问 `http://127.0.0.1:4300/`，后台登录用户名默认 `operator`，密码为 `.env` 的 `ADMIN_TOKEN`。

## 构建 / 测试

```sh
make build           # native server + frontend js
make test            # 运行测试（当前无测试入口）
make init-env        # 生成 .env 模板（不覆盖已有）
moon fmt             # 格式化
```

## 能力

- **阅读**：`/d/{slug}` 服务端渲染阅读页（面包屑 + 文档树 + tags + 产品名 title）；`/` 是 full-rabbita SPA（SSR + 水合）。
- **认证**：API key（Bearer，可绑定用户 + 读/写 slug 前缀范围）或 cookie session（浏览器自动携带）。
- **权限分层**：`superadmin` > `admin` > `write` > `read` > `none`；admin 不能管理 superadmin。
- **站点设置**：产品名、公开/私有（`site.public`）、文档树、`llms.txt` 三档策略（public/partial/disabled + 前缀过滤）。
- **后台管理**：用户 CRUD + 密码重置 + 启停；API key 创建/吊销 + 范围绑定；站点设置。
- **安全**：slug 路径穿越防护（`..`/`.`/绝对路径拒绝）、API key 范围过滤、越权禁止。

## API

见 [`docs/API.md`](docs/API.md)（REST 契约）。服务端点包括：

```text
GET    /health
GET    /d/*slug                服务端渲染阅读页
GET    /llms.txt
GET    /api/v1/config
GET    /api/v1/docs
GET    /api/v1/docs/*slug
PUT    /api/v1/docs/*slug     （需写权限 + 前缀范围）
DELETE /api/v1/docs/*slug     （需写权限 + 前缀范围）
POST   /api/auth/login         返回 {token,role} + 设 mbt_auth cookie
POST   /api/auth/logout
GET    /api/auth/me
GET    /api/admin/users        （仅管理员）
POST   /api/admin/users        （仅管理员）
POST   /api/admin/users/update
POST   /api/admin/users/password
GET    /api/admin/keys         （仅管理员）
POST   /api/admin/keys
POST   /api/admin/keys/revoke
GET    /api/admin/site         （仅管理员）
POST   /api/admin/site
```
