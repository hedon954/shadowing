# ADR-0002: MVP 采用原生 Swift 技术栈

- Status: Accepted
- Date: 2026-07-11

## Context

MVP 的关键路径是 MP3 解码、播放、变速、麦克风录制、设备权限和 SwiftUI
波形交互。这些能力直接由 Apple 框架提供。当前没有跨平台、AI 评分或复杂
后端规则，立即引入 Rust 会增加 FFI、动态库嵌入、签名和双语言 CI 成本。

## Decision

- 使用 SwiftUI 构建 macOS 15+ 应用，Swift 语言模式为 Swift 6。
- 使用 AVFoundation/Core Audio 完成实时音频能力。
- MVP 不引入 Rust、UniFFI 或 cargo-swift。
- 通过 repository/store 协议隔离持久化实现，使未来可接入 UniFFI adapter。
- 使用 XcodeGen 维护工程定义，生成的 `.xcodeproj` 不提交。

## Consequences

### Positive

- 音频链路和 UI 在同一运行时内，调试与发布路径最短。
- 避免当前没有产品收益的跨语言复杂度。

### Negative

- 未来离线 DSP 或跨平台需求可能需要迁移部分实现。
- 与 lumen-pdf 的 Rust 核心不完全同构。

## Alternatives Considered

- Swift + Rust + UniFFI：当前 Rust 仅能承担较薄的持久化职责，收益不足。
- cargo-swift：它是基于 UniFFI 的 SPM 打包工具，不是 FFI 本体，也非必需。

## Verification

- `make build` 和 `make test` 不依赖 Rust 工具链。
- `Domain` 与 `ViewModels` 不导入具体数据库框架。

## References

- [Shadowing MVP PRD](../prd/prd-v0.0.1-2026-07-11.md)
- [ADR-0010](0010-rust-uniffi-adoption-threshold.md)
