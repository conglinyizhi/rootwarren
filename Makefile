# mbt-mdwiki 构建辅助
# 说明：本机 MoonBit nightly 默认 archiver 探测有误（找 /usr/bin/lib.exe），
# 需要显式指定 MOON_CC=clang（warren + native 后端均需要）。
MOON ?= moon
export MOON_CC ?= clang

.PHONY: run build build-frontend test check fmt clean init-env dev

build-frontend:
	$(MOON) build frontend --target js

run: build-frontend
	$(MOON) run cmd/main -- $(ARGS)

# warren 全栈开发模式（SSR + 前端水合 + moonback API + 热更新）
dev:
	$(MOON) build cmd/server --target native
	warren dev --browser-entry cmd/browser --server-entry cmd/server --server-target native

init-env:
	$(MOON) run cmd/main -- --init-env

build: build-frontend
	$(MOON) build cmd/main --target native

test:
	$(MOON) test

check:
	$(MOON) check
	$(MOON) check frontend --target js

fmt:
	$(MOON) fmt

clean:
	$(MOON) clean
