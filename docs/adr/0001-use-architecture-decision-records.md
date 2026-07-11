# ADR-0001: 采用 ADR 管理架构决策

- Status: Accepted
- Date: 2026-07-11

## Context

Shadowing 从零开始，音频同步、持久化和未来跨语言边界都具有较高变更成本。
仅在聊天或代码中保留决策会导致背景丢失，也难以判断旧约束是否仍然有效。

## Decision

- 在 `docs/adr` 使用编号 ADR 记录长期技术决策。
- 已接受 ADR 不做语义改写；变化通过新 ADR 标记 `Superseded`。
- 尚需技术验证的结论使用 `Proposed`，通过验证后才改为 `Accepted`。
- PR 必须链接受影响的 ADR；架构变化应先更新或新增 ADR。

## Consequences

决策背景可追溯，但每次架构变化会增加少量文档维护成本。

## Verification

- `scripts/validate-architecture.sh` 检查 ADR 必要章节。
- ADR 索引能链接到所有正式 ADR。
