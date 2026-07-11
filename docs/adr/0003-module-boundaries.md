# ADR-0003: 模块边界与依赖方向

- Status: Accepted
- Date: 2026-07-11

## Context

音频回调、界面状态和持久化若相互直接调用，会形成难以测试的全局状态。
同时，未来可能把持久化实现替换为 Rust/UniFFI。

## Decision

源码按职责组织：

```text
App → Features/ViewModels → Domain
             ↓                ↑
          Services ───────→ Protocols
             ↓
       Audio/Persistence
```

- `Views` 只渲染状态并转发用户意图，不直接访问 AVFoundation、SQLite 或文件。
- `ViewModels` 在 `@MainActor` 协调 use case 和可观察状态。
- `Domain` 包含值对象、状态机和 repository/store 协议，不依赖 UI 或 I/O 框架。
- `Audio` 封装实时播放、录音和波形采样。
- `Persistence` 实现 Domain 协议；具体数据库类型不得越过该边界。
- 仅在存在测试或替换边界时引入协议，避免为分层而分层。

## Consequences

依赖可替换且测试更容易，但简单功能会多一层显式协调代码。

## Verification

- 架构校验禁止 `Views` 导入 `AVFoundation` 或数据库模块。
- repository 的测试使用内存或临时目录实现。
