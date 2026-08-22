# mbt-mdwiki 构建辅助
# 说明：本机 MoonBit nightly 默认 archiver 探测有误（找 /usr/bin/lib.exe），
# 需要显式指定 MOON_CC=gcc。
MOON ?= moon
export MOON_CC ?= gcc

.PHONY: run build build-frontend test check fmt clean

build-frontend:
	$(MOON) build frontend --target js

run: build-frontend
	$(MOON) run cmd/main

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
