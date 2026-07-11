# ADR-0010: 引入 Rust/UniFFI 的门槛

- Status: Accepted
- Date: 2026-07-11

## Context

纯 Swift 是 MVP 的最短路径，但未来离线 DSP、发音分析或跨平台可能让 Rust
核心具有价值。过早预留具体 FFI 类型会固化尚未验证的边界。

## Decision

当前只保留 Swift repository/store 协议，不创建空 Rust crate。满足以下任意
两项后，才通过新 ADR 评估 Rust：

1. 六个月路线图内包含显著离线 DSP、音素分析或 AI 推理。
2. 明确支持 Windows/Linux，且核心逻辑可实际复用。
3. 多区间、同步或迁移规则形成复杂且稳定的领域核心。
4. 团队愿意承担双语言 CI、FFI 兼容性、签名与发布成本。
5. 已有性能测量证明 Swift/Accelerate 方案不满足目标。

若引入 Rust：

- 实时 AVFoundation 回调和 Apple 权限 API 仍留在 Swift。
- 使用 UniFFI proc-macro 与显式构建脚本。
- cargo-swift 仅在必须产出 SPM 包时评估，不作为 UniFFI 的默认组成。
- Rust adapter 实现现有 Swift 协议，不让 UI 直接依赖生成类型。

## Consequences

避免投机性双栈，同时为基于证据的演进保留清晰入口。

## Verification

- 当前工程不要求安装 Rust。
- 每次提议 Rust 前附性能、跨平台或复杂度证据，并逐项检查上述门槛。
