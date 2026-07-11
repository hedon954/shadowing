# ADR-0006: SQLite 元数据与文件存储

- Status: Accepted
- Date: 2026-07-11

## Context

Recordings 页面需要按时间排序并聚合 Take 数量；练习状态需要一致恢复。
录音文件体积较大，放入数据库 BLOB 不利于播放、迁移和磁盘故障处理。

## Decision

- SQLite 保存项目、练习区间快照、Take、最近文件和 schema migration。
- 录音与波形缓存保存在文件系统；数据库只记录稳定的相对路径和元数据。
- 轻量界面偏好使用 UserDefaults。
- Domain 仅依赖 `ProjectRepository`、`TakeRepository`、`SettingsStore`、
  `RecordingFileStore` 和 `BookmarkStore` 协议。
- SQLite 实现放在 `Persistence`；未来 UniFFI 实现必须遵守相同协议语义。
- 创建 Take 使用“临时文件 → 校验 → 原子移动 → 数据库事务”顺序。
- 删除使用可恢复顺序，避免数据库引用不存在的文件。

## Consequences

查询与迁移能力优于 JSON 目录扫描，但需要维护 schema 版本和文件/记录一致性。

## Verification

- migration 测试从每个历史 schema 升级到最新版本。
- 崩溃恢复测试覆盖临时文件、孤立文件和缺失文件。
- repository contract tests 可复用于 SQLite 和未来 UniFFI adapter。
