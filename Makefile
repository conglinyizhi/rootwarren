# mbt-mdwiki 构建辅助
# 说明：本机 moon nightly 默认 archiver 探测有误（找 /usr/bin/lib.exe），
# 需要显式指定 MOON_CC=gcc；见 docs/API.md 或 README。
MOON ?= moon
export MOON_CC ?= gcc

.PHONY: run build test check fmt clean

run:
	$(MOON) run cmd/main

build:
	$(MOON) build --target native

test:
	$(MOON) test

check:
	$(MOON) check

fmt:
	$(MOON) fmt

clean:
	$(MOON) clean
