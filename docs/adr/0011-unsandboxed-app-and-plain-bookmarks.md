# ADR-0011: 暂不启用 App Sandbox，书签不带安全作用域

- Status: Accepted
- Date: 2026-10-05
- Owners: Shadowing maintainers
- Supersedes: ADR-0007 中“启用 App Sandbox”和“保存 security-scoped bookmark”的部分

## Context

ADR-0007 决定启用 App Sandbox 并保存 security-scoped bookmark。实际使用中，应用一直以
无签名、未沙盒的方式运行，项目数据库、录音和波形缓存都在
`~/Library/Application Support/Shadowing`，Focus 也从这个路径读取数据。启用沙盒后应用会
改读空的沙盒容器，已有项目和 Take 看起来会全部丢失。

security-scoped bookmark 与创建它的代码签名绑定。每次无签名重建或换签名后，旧书签用
`.withSecurityScope` 解析会失败（“格式不正确”），但不带作用域解析仍然可用，文件也可读。

## Decision

- 暂不启用 App Sandbox：entitlements 不包含 `com.apple.security.app-sandbox`，数据继续
  保存在 `~/Library/Application Support/Shadowing`。
- 保留 `com.apple.security.device.audio-input` 和
  `com.apple.security.files.user-selected.read-write` 声明，便于以后重新启用沙盒；未沙盒时
  它们不起作用。
- 未沙盒时书签的创建和解析都不带 `.withSecurityScope`；普通解析同样能打开旧的带作用域
  书签，`isStale` 以系统返回为准，打开项目不会每次都重写书签。
- 只有沙盒中才带作用域创建和解析书签；带作用域解析失败时回退为普通解析，回退成功即按
  当前方式重新保存该项目的书签。
- 解析失败时抛出原始错误（沙盒中为带作用域解析的错误），继续进入“定位文件”流程。
- `startAccessingSecurityScopedResource()` 返回 false 不视为无权限，只有文件存在但不可读
  时才报告无权访问。
- ADR-0007 其余决定（只读源文件、stale 与重新定位流程、作用域成对管理）继续有效。

## Consequences

### Positive

- 已有项目、录音和 Focus 的读取路径保持不变，无需数据迁移。
- 无签名重建不会让新保存的书签失效；旧的带作用域书签可以继续打开并自动更新。

### Negative

- 应用不受沙盒保护，不能以当前形态上架 Mac App Store。
- 以后重新启用沙盒时需要新 ADR，并迁移数据到容器、重新创建带作用域的书签。

## Alternatives Considered

- 启用沙盒并把数据迁移到容器：需要同时修改 Focus 的读取路径，并引入迁移与回滚风险，
  当前收益不足。
- 继续创建带作用域的书签：每次无签名重建都会让书签失效，用户只能逐个重新定位文件。

## Verification

- `codesign -d --entitlements - Shadowing.app` 不包含 `com.apple.security.app-sandbox`。
- `BookmarkFallbackTests` 覆盖未沙盒时只做普通解析且不重写书签、沙盒中回退解析成功并重新
  保存书签、解析失败时进入定位流程。
- 用已有数据库副本验证旧书签都能通过回退解析打开。

## References

- [ADR-0007：沙盒文件访问与源文件重定位](0007-sandboxed-file-access.md)
- `Shadowing/Shadowing.entitlements`
- `Shadowing/Services/SecurityScopedBookmarkStore.swift`
