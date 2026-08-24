---
title: API 文档
tags: api, moonbit, agent
category: api
---

# API 文档

本目录 `api/` 是独立的文档目录，用于演示多 wiki 目录存储的能力——每个目录就是一套 wiki 集合，slug 带目录前缀。

本站提供受保护的 REST API，供 LLM 与客户端读写 Markdown 文档。

## 文档接口

- `GET /api/v1/docs` 列出全部文档。
- `GET /api/v1/docs/{slug}` 读取一篇文档，返回 `slug`、渲染后的 `html`、Markdown 原文 `content`、`category`、`status`。
- `PUT /api/v1/docs/{slug}` 创建或覆盖一篇文档（需要写权限）。
- `DELETE /api/v1/docs/{slug}` 删除一篇文档（需要写权限）。

## 认证

客户端通过 `Authorization: Bearer <api_key>` 认证；浏览器走 HttpOnly cookie session。

- API key 有 `read` / `read,write` 权限，可绑定用户并限制读写前缀。
- 密钥生成时仅展示一次明文，后端只存 SHA-256 哈希。

## 其他端点

- `GET /api/auth/me` 当前登录状态与角色、可编辑权限。
- `GET /api/v1/backlinks/{slug}` 查询链入某篇文档的文档（反向链接）。
- `GET /api/v1/categories` 列出全部分类。
- `GET /feed` RSS 2.0 订阅。
- `GET /llms.txt` LLM 文档索引。

完整契约见仓库 `docs/API.md`。
