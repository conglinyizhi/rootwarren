# mbt-mdwiki 设计文档

- 日期：2026-08-22
- 状态：已确认（brainstorming 完成）
- 目标交付：黑客松申报原型（几天内可演示）

## 1. 背景与目标

用 MoonBit 语言编写一个文档站后端：以文件系统上的 Markdown 为内容源，对外提供受保护的 REST API，让人类浏览器和大语言模型客户端都能安全地读写文档。项目面向黑客松申报，核心卖点是「让大模型通过受保护的 API 安全接入文档」，而不是传统意义上的 CMS。

## 2. 定位与核心价值

- **后端优先**：API + 鉴权是主干，前端只留极简演示页。
- **给大模型用**：LLM 客户端（或读了接入指南后自封装 skill 的任意 agent）通过 REST API 增删改查文档。
- **安全暴露**：API key 鉴权 + 读写 scope，是区别于「裸 skill 放公网」的核心价值。
- **人可浏览**：`GET /d/{slug}` 渲染 HTML，给人看。
- **接入指南即交付物**：项目附带 AGENTS.md / API.md，写清项目是什么、API 怎么调、鉴权怎么配，让陌生 LLM 读后即可接入。

## 3. 硬约束

- 不使用 Docker / 容器化。
- 单二进制部署（`moon build --target native`），systemd 直跑。
- 内存占用优先于 CPU。
- 依赖少、概念少、可部署、可回退。
- 不做微服务。

## 4. 架构总览

```
┌────────────────────────────────────────────────────┐
│  mbt-mdwiki  MoonBit 单二进制                        │
│                                                    │
│  moonbitlang/async (@http.Server, 原生异步)          │
│  ┌──────────┬───────────┬──────────┬────────────┐  │
│  │ 网页渲染   │ REST API  │ 后台管理  │  （无 MCP） │  │
│  │ GET /d/   │ /api/v1/* │ /admin/* │            │  │
│  │ :slug     │ (API key) │ (登录+   │            │  │
│  │ cmark→HTML│           │  配置)   │            │  │
│  └──────────┴───────────┴──────────┴────────────┘  │
│                                                    │
│  Storage trait（抽象层）                             │
│   └─ LocalStorage → content/*.md   SQLite: meta.db │
│      （内容，git 可管）               （配置/key/索引）│
└────────────────────────────────────────────────────┘
```

设计原则：

1. 一个进程、一个二进制：HTTP + API + 后台全在一个 MoonBit 程序里。
2. 文件系统是内容源，SQLite 是元数据：Markdown 文件是唯一真相，SQLite 只存配置、API key、文档索引。
3. 鉴权分两层：人走后台登录会话，机器走 `Authorization: Bearer <api_key>`（只存哈希，scope 分读写）。
4. 前端是最薄的一层：极简演示页，真正的客户端由第三方自行实现。
5. 无 MCP 层：MCP 由客户端侧自行封装，服务端只提供干净的 REST API + 接入指南。

## 5. 技术选型（MoonBit 生态）

| 能力 | 选型 | 备注 |
|---|---|---|
| HTTP 服务端 | `moonbitlang/async`（官方原生异步） | API 未稳定，但 MVP 够用；社区框架 crescent/mars 作为备选 |
| SQLite | `mizchi/sqlite` | 维护最活跃，native + JS 双端 |
| Markdown 渲染 | `moonbit-community/cmark` | 严格 CommonMark + HTML renderer |
| 哈希（API key） | 标准库（如 `@crypto` 相关）或简单哈希 | key 只存哈希不存明文 |
| 向量搜索 | 不选型（phase 2） | MVP 用关键词搜索 |

工具链为 nightly 版本，生态信息以 GitHub / 官网 / mooncakes.io 当前状态为准，本设计不绑定未验证的 API 细节。

## 6. 数据模型与存储布局

### 文件系统（内容唯一真相）

```
content/
  index.md              ← 站点首页
  guide/
    getting-started.md  ← slug: guide/getting-started
    api.md              ← slug: guide/api
  concepts/
    vector-search.md
meta.db                 ← SQLite（配置/密钥/索引）
```

slug 即相对路径去扩展名，天然唯一。`content/` 由 git 管理，回退靠 git。

### 存储抽象层（Storage trait）

```moonbit
/// 内容存储抽象：MVP 只实现本地文件，后续可加内存盘（测试）/对象存储
trait Storage {
  read(slug : String) -> Option[String]   // 读原始 Markdown
  write(slug : String, content : String) -> Unit?  // 写
  delete(slug : String) -> Unit?         // 删
  list() -> Iter[String]                  // 全部 slug
}
```

- MVP 实现 `LocalStorage`：映射到 `content/` 目录，路径安全校验（防 `../` 逃逸）。
- Phase 2 实现：`MemoryStorage`（测试/演示，纯内存零 IO）、`ObjectStorage`（多位置容器）。
- 服务端代码只依赖 trait，不直接碰文件系统；换实现不动业务逻辑。
- 不做事务、不做插件机制（避免过度设计）。

### SQLite 表（MVP 三张）

| 表 | 字段 | 作用 |
|---|---|---|
| `config` | key, value | 站点标题/描述/搜索模式等键值配置 |
| `api_keys` | id, name, key_hash, scopes, enabled, created_at | API key 管理；只存哈希，scopes 区分读写 |
| `doc_index` | slug, title, updated_at, content_hash | 文档元数据 + 搜索索引；正文不冗余进库 |

### 搜索策略

- **MVP（关键词搜索）**：文档量几十篇规模，读 `content/` 文件做包含匹配 + `doc_index` 标题权重排序，毫秒级，零额外依赖。
- **Phase 2（向量搜索，文本文件存储）**：嵌入向量序列化为文本/JSON 文件（`meta/vectors/` 每篇一个 `.json`），启动时读进内存算余弦相似度。不引入二进制向量库，天然可 git、可回退。

## 7. API 设计

鉴权：`Authorization: Bearer <api_key>`，key 只存哈希；scopes 分 `read` / `read+write`。

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| GET | /api/v1/docs | read | 列出全部文档（slug+标题） |
| GET | /api/v1/docs/{slug} | read | 取文档（?format=raw\|html） |
| PUT | /api/v1/docs/{slug} | write | 创建/覆盖文档 |
| DELETE | /api/v1/docs/{slug} | write | 删除文档 |
| GET | /api/v1/search?q= | read | 关键词搜索 |
| GET | /api/v1/config | read | 读站点配置 |
| GET | /api/v1/health | 公开 | 健康检查（无需 key，部署用） |

网页端：`GET /d/{slug}` 渲染 HTML（公开，给人看）；`/admin/*` 登录后管理。

错误响应统一 JSON 格式：`{"error": {"code": "...", "message": "..."}}`，状态码语义标准（401 未授权 / 403 权限不足 / 404 不存在 / 409 冲突等）。

## 8. 后台管理

`/admin/*` 登录后可用，功能：

1. 站点信息：标题、描述、默认语言。
2. API key 管理：新建/吊销/启用/禁用，读写 scope。
3. 搜索模式开关：关键词 / 向量（phase 2 加）。

服务端口、存储路径等启动参数走 CLI flag + 环境变量，不进后台——运行参数和内容配置分开，避免后台改错把自己锁死。

## 9. 接入指南（交付物）

项目根目录包含：

- `AGENTS.md`：项目是什么、架构概览、如何本地运行、如何测试。
- `docs/API.md`：完整 API 文档（端点、鉴权、错误、示例 curl）。
- 示范：LLM 如何用 API 自封装 skill / MCP 工具（代码示例）。

这是黑客松演示的关键材料：给一个陌生 LLM 这份指南，它应能直接接入。

## 10. MVP 范围与里程碑

| 天 | 交付 | 验证信号 |
|---|---|---|
| D1 | 项目骨架 + Storage trait + LocalStorage + HTTP 服务 + /health | `moon run` 起来，curl /health 通 |
| D2 | REST API 全套 + Bearer 鉴权（key 哈希存储、scope 校验） | curl 带 key 增删改查全通；无 key 401 |
| D3 | cmark 渲染 /d/{slug} + 后台登录 + API key 管理页 | 浏览器看文档页；后台能新建/吊销 key |
| D4 | 接入指南（AGENTS.md + API.md）+ 演示脚本 + 收尾 | LLM 客户端照指南接入成功；申报材料截图齐 |

优先级：D2 是生命线（API + 鉴权做扎实）；D3 渲染/后台可砍到最简；D4 指南必须完整。

## 11. 非目标（Out of Scope）

- MCP Server：切掉，客户端自行封装。
- 第三方登录（OAuth）：进 backlog，站点公开运营、多管理员时再做（phase 2）。
- 向量搜索：phase 2，MVP 不涉及嵌入模型。
- 多用户 / 团队权限：MVP 单管理员 + API key scope。
- 在线 Markdown 编辑器：MVP 不做（内容靠文件/git/API 写入）。
- 版本历史 API：MVP 不做（依赖 git 管理 content/）。
- 容器化 / 微服务 / 分布式：明确不做。

## 12. 错误处理与安全

- 路径安全：LocalStorage 校验 slug，防目录穿越。
- 密钥安全：API key 只存哈希，后台展示明文仅一次（创建时）。
- 登录会话：后台登录用 session cookie + 密码（或初始 token），MVP 单管理员。
- 输入校验：slug 白名单字符（`[a-zA-Z0-9-_/]`），content 长度上限。
- 并发写：单进程 + SQLite WAL 或写入锁，MVP 级别足够。
- 启动参数分离：端口/路径走 CLI/env，不在后台改。

## 13. 测试策略

- Storage trait 用 `MemoryStorage` 测试业务逻辑，零磁盘 IO。
- API 层用 HTTP 客户端（`@http`）进程内测试：鉴权、CRUD、搜索、错误路径。
- LocalStorage 路径逃逸单测（`../`、绝对路径、空 slug）。
- 端到端：启动服务 + curl 脚本验证 D1-D4 各里程碑信号。
