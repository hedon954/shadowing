# Changelog

Shadowing 的版本记录由人工维护。每个版本只记录对用户有意义的变化；
GitHub Release 直接读取本文件中对应版本段落，不在 workflow 里自动生成文案。

---
## [0.0.1] - 2026-07-12

首个可本地练习的 MVP 闭环：打开 MP3、选区循环、同步录音、多 Take 对比与本地恢复。

### 新增

- Library：打开 / 恢复本地 MP3，统一 Projects 列表
- Practice：Original 与多条 Take 对齐、选区循环、变速与录音
- 覆盖重录按原音时间轴合并，空隙补静音；Take 可拖拽排序
- 本地 SQLite + 文件存储，无账号、无上传

### 工程

- XcodeGen + `make check` 质量门禁
- `v*` tag 触发 Release workflow，打包无签名 DMG（正式签名 / 公证见 ADR-0009）
