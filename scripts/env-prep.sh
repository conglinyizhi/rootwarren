#!/usr/bin/env bash
#
# 确保 .env 存在并可用（含后端登录凭据 ADMIN_TOKEN）。
#
# 用法:
#   ./scripts/env-prep.sh            # 开发/测试：缺失时自动生成随机密码并打印凭据
#   ./scripts/env-prep.sh --require  # 生产/正式：缺失时给出配置指引并退出(不静默生成)
#
# 说明:
#   - .env 由本脚本自动生成时，会写入随机强密码到 ADMIN_TOKEN，并打印一次登录凭据。
#   - .env 已存在时不动它（复用已有的 ADMIN_TOKEN / PORT 等），静默通过。
#   - 不要提交 .env 到 git。

set -euo pipefail

ENV_FILE=".env"
REQUIRE=0
if [ "${1:-}" = "--require" ]; then
  REQUIRE=1
fi

# 已存在：直接复用，不覆盖。静默通过（避免每次 make 都刷屏）。
if [ -f "$ENV_FILE" ]; then
  exit 0
fi

# 需要配置但缺失：给出提示并退出，交给用户手动完成。
if [ "$REQUIRE" = "1" ]; then
  cat >&2 <<'MSG'
[错误] 缺少 .env 配置文件，未设定后端登录凭据。

请先完成配置后再运行：
  1) cp .env.example .env
  2) 编辑 .env，把 ADMIN_TOKEN 设为强密码（用户名固定为 operator）
  3) 重新执行 make run

提示：生成随机密码可用
  openssl rand -hex 16
MSG
  exit 1
fi

# 开发/测试：自动生成随机的 ADMIN_TOKEN 并写入 .env。
TOKEN="$(openssl rand -hex 16 2>/dev/null || od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"

cat > "$ENV_FILE" <<EOF
# mbt-mdwiki 本地配置（开发环境自动生成，勿提交到 git）
# 后台登录初始密码（用户名固定为 operator，可登录后在后台修改）
ADMIN_TOKEN=$TOKEN
# 监听地址（make run 生效；warren dev 固定使用 4300）
MBT_MDWIKI_IP=0.0.0.0
PORT=8001
EOF

echo '已自动生成 .env（开发环境）。'
echo '后台登录凭据：'
echo '  用户名: operator'
echo "  密码:   $TOKEN"
echo '说明: 此密码已写入 .env 的 ADMIN_TOKEN 字段，忘记时可查看该文件。'
