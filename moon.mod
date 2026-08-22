// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "conglinyizhi/mbt-mdwiki"

version = "0.1.0"

readme = "README.mbt.md"

repository = ""

license = "Apache-2.0"

keywords = []

preferred_target = "native"

description = "mbt-mdwiki: MoonBit 文档站后端，提供受保护的 REST API 供 LLM 读写 Markdown 文档"

import {
  "moonbitlang/async@0.21.0",
  "mizchi/sqlite@0.3.1",
  "moonbit-community/cmark@0.4.6",
}
