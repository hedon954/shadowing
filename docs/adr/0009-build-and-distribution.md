# ADR-0009: 构建、签名与分发

- Status: Accepted
- Date: 2026-07-11

## Context

macOS 应用最终需要签名、公证和 DMG，但开发初期没有发布凭据。提交生成的
Xcode 工程也容易和 XcodeGen 配置发生漂移。

## Decision

- `Shadowing/project.yml` 是工程唯一事实来源，`.xcodeproj` 不提交。
- Makefile 封装 XcodeGen 与 xcodebuild，本地和 CI 使用相同脚本。
- CI 使用无签名 Debug build 和 tests。
- 发布阶段再增加 Developer ID 签名、公证、universal archive 与 DMG 脚本。
- GitHub Release 仅由 `v*` annotated tag 触发，版本号与 changelog 必须先更新。

## Consequences

开发期构建简单且无凭据依赖；正式分发流程必须在首个外部版本前另行验证。

## Verification

- 删除 `.xcodeproj` 后执行 `make generate && make build` 可恢复工程。
- CI 不需要 Apple signing secrets。
- 首次外部分发前新增 release ADR 或将本 ADR 的发布部分验证为 Accepted。
