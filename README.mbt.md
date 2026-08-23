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
make dev              # 自动准备 .env + 起 warren 全栈 dev server（端口 4300）
```

访问 `http://127.0.0.1:4300/`。

**开发环境登录**：`make dev` 会在 `.env` 缺失时自动生成一个（含随机 `ADMIN_TOKEN`），并在终端打印一次登录凭据。之后登录后台：

```text
用户名: operator
密码:   <make dev 自动生成的随机值，见 .env 的 ADMIN_TOKEN>
```

> `make dev` 是自动生成（测试/开发即开即用）；**生产/正式**请用 `make run`，它要求先手动配置 `.env`，缺失时会给出指引并退回，不自动生成。

## 构建 / 测试

```sh
make build           # native server + frontend js
make test            # 运行测试（当前无测试入口）
make init-env        # 生成 .env 模板（不覆盖已有）
moon fmt             # 格式化
```

## 登录与配置

后端登录凭据由 `.env` 提供（`ADMIN_TOKEN`=初始密码，用户名固定 `operator`）。`.env` 是 gitignored 的本地配置。

- **开发/测试**：运行 `make dev`，若 `.env` 不存在会自动生成（随机强密码），首次生成会在终端打印登录凭据；`.env` 已存在则复用、不覆盖。
- **生产/正式**：运行 `make run`，若 `.env` 缺失会打印配置指引并退出。请先手动配置：

```sh
cp .env.example .env
# 编辑 .env，把 ADMIN_TOKEN 设成强密码
openssl rand -hex 16   # 可用于生成强密码
make run
```

配置说明：

| 键 | 含义 |
| --- | --- |
| `ADMIN_TOKEN` | 后台初始登录密码（用户名固定 `operator`），登录后可在后台改为持久密钥 |
| `MBT_MDWIKI_IP` | `make run` 监听地址 |
| `PORT` | `make run` 端口（`warren dev` 固定用 4300） |

> 环境变量优先于 `.env`：若在 shell 已设置同名变量，则 `.env` 不覆盖它。

## 能力

- **阅读**：`/d/{slug}` 服务端渲染阅读页（面包屑 + 文档树 + tags + 产品名 title）；`/` 是 full-rabbita SPA（SSR + 水合）。
- **类型化内容（Typecho 式）**：文档可设 `status`（public/private/hidden/draft）与 `category`；分类聚合 + `/category/{slug}` 分类页；`/posts/{slug}` 固定链接；`/feed` RSS 2.0 订阅。
- **认证**：API key（Bearer，可绑定用户 + 读/写 slug 前缀范围）或 cookie session（浏览器自动携带）。
- **权限分层**：`superadmin` > `admin` > `write` > `read` > `none`；admin 不能管理 superadmin。
- **站点设置**：产品名、公开/私有（`site.public`）、文档树、`llms.txt` 三档策略（public/partial/disabled + 前缀过滤）。
- **后台管理**：用户 CRUD + 密码重置 + 启停；API key 创建/吊销 + 范围绑定；站点设置；分类查看。
- **安全**：slug 路径穿越防护（`..`/`.`/绝对路径拒绝）、API key 范围过滤、越权禁止。

## API

见 [`docs/API.md`](docs/API.md)（REST 契约）。服务端点包括：

```text
GET    /health
GET    /d/*slug                服务端渲染阅读页
GET    /llms.txt
GET    /feed                    RSS 2.0 订阅
GET    /category/*slug         分类页（SSR）
GET    /posts/*slug            文章固定链接（SSR）
GET    /api/v1/categories      分类列表 + 计数
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
