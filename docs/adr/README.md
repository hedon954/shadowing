# Shadowing Architecture Decision Records

ADR 记录具有长期影响的技术决策。状态使用 `Proposed`、`Accepted`、
`Superseded` 或 `Rejected`；已接受的 ADR 只能由新 ADR 取代，不直接改写历史。

## Phase 0：开工前基线

- [ADR-0001：采用 ADR 管理架构决策](0001-use-architecture-decision-records.md)
- [ADR-0002：MVP 采用原生 Swift 技术栈](0002-native-swift-mvp-stack.md)
- [ADR-0003：模块边界与依赖方向](0003-module-boundaries.md)
- [ADR-0008：测试策略与质量门禁](0008-testing-and-quality-gates.md)

完成条件：工程可生成、构建和测试，`make check` 在本地与 CI 行为一致。

## Phase 1：音频核心

- [ADR-0004：AVFoundation 音频引擎与同步模型](0004-avfoundation-audio-engine.md)
- [ADR-0005：波形生成、缓存与渲染](0005-waveform-processing.md)

完成条件：通过技术 Spike 验证 MP3 播放、选区循环、同步录音和双轨波形。

## Phase 2：本地数据闭环

- [ADR-0006：SQLite 元数据与文件存储](0006-local-persistence.md)
- [ADR-0007：沙盒文件访问与源文件重定位](0007-sandboxed-file-access.md)

完成条件：完成多 Take 持久化、重启恢复、源文件重定位和失败回滚。

## Phase 3：交付与演进

- [ADR-0009：构建、签名与分发](0009-build-and-distribution.md)
- [ADR-0010：引入 Rust/UniFFI 的门槛](0010-rust-uniffi-adoption-threshold.md)

完成条件：CI 构建稳定；发布前补齐签名、公证和 DMG 流程。仅在 ADR-0010
的触发条件满足后评估 Rust。

## 新增 ADR

复制 [template.md](template.md)，使用四位递增编号和 kebab-case 文件名。
ADR 至少包含 Context、Decision、Consequences 和 Verification。
