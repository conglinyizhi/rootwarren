# rootwarren 构建辅助
# 说明：本机 MoonBit nightly 默认 archiver 探测有误（找 /usr/bin/lib.exe），
# 需要显式指定 MOON_CC=clang（warren + native 后端均需要）。
MOON ?= moon
export MOON_CC ?= clang

.PHONY: run build build-frontend test check fmt clean init-env dev

# warren 全栈开发模式（SSR + 前端水合 + moonback API + 热更新）
# 先确保 .env 存在：缺失时自动生成随机 ADMIN_TOKEN 并打印登录凭据（开发环境）。
dev:
	$(MOON) build cmd/server --target native
	@bash scripts/env-prep.sh
	rm -f public/index.js
	warren dev --browser-entry cmd/browser --server-entry cmd/server --server-target native

# 直接运行 native 全栈 server（不含热更新）
# 生产/正式：要求 .env 已配置；缺失时给出指引并退出，不自动生成。
run:
	@bash scripts/env-prep.sh --require
	$(MOON) run cmd/server -- $(ARGS)

# 构建 native server + 前端水合 bundle
build:
	$(MOON) build cmd/server --target native
	$(MOON) build cmd/browser --target js

build-frontend:
	$(MOON) build cmd/browser --target js

# 生成 .env 配置模板（不覆盖已有文件）
init-env:
	@if [ -f .env ]; then echo ".env 已存在，未覆盖。"; else \
	  printf '%s\n' '# rootwarren 本地配置模板' '# 后台网页登录初始密码，用户名默认是 operator，可在后台修改' 'ADMIN_TOKEN=replace-me' '# 监听地址' 'MBT_MDWIKI_IP=0.0.0.0' 'PORT=8001' > .env; \
	  echo "已生成 .env 配置模板，请编辑 ADMIN_TOKEN 后再启动。"; \
	fi

test:
	$(MOON) test

check:
	$(MOON) check

fmt:
	$(MOON) fmt

clean:
	$(MOON) clean
