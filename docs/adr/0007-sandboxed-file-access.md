# ADR-0007: 沙盒文件访问与源文件重定位

- Status: Accepted
- Date: 2026-07-11

## Context

Shadowing 引用用户选择的 MP3 而不复制源文件。启用 App Sandbox 后，普通
文件路径不能保证应用重启后仍可访问，源文件也可能被移动或删除。

## Decision

- 应用启用 App Sandbox、麦克风和 user-selected read-only 权限。
- 用户选择文件后保存 security-scoped bookmark data，不只保存绝对路径。
- 每次访问都成对调用 start/stop accessing，并限制作用域持有时间。
- bookmark stale 或文件缺失时进入“重新定位”流程；匹配后更新 bookmark。
- 用户录音目录由应用管理；若允许自定义目录，同样保存目录 bookmark。
- Rust adapter 将来只接收已解析的数据或 bookmark bytes，不负责调用 Apple API。

## Consequences

重启访问可靠且满足沙盒要求，但需要显式管理 bookmark 生命周期和错误状态。

## Verification

- 重启应用后可重新打开最近文件。
- 移动源 MP3 后可以重新定位且保留原有选区与 Take。
- 权限撤销时显示可恢复错误，不删除项目数据。
