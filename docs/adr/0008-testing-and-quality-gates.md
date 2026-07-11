# ADR-0008: 测试策略与质量门禁

- Status: Accepted
- Date: 2026-07-11

## Context

实时音频难以完全自动化，但选区规则、状态机、repository contract 和文件事务
可以稳定测试。若本地与 CI 使用不同命令，门禁会逐渐失效。

## Decision

- `make check` 是完整质量门禁的单一入口。
- 单元测试覆盖 Domain 值对象、状态转换和错误分支。
- contract tests 覆盖每个 repository 实现。
- 音频调度逻辑依赖可注入 clock/scheduler；硬件行为保留 Spike 与手工清单。
- SwiftFormat 和 SwiftLint 负责机械规范，编译器 warning 视为错误。
- pre-commit 运行快速静态检查；完整 build/test 在 CI 和提交前按需运行。

## Consequences

反馈速度与覆盖率平衡，但真实设备路由、延迟和麦克风异常仍需要手工验证。

## Verification

- `make check` 可在干净 clone 和 GitHub Actions 上成功运行。
- 失败的格式、lint、测试或架构检查都会返回非零状态。
