# Shadowing Engineering Principles

本文件定义 Shadowing 的长期工程原则、软件开发规范、架构边界和 Git/发布
文案规范，是仓库内 coding agent 的最高级工程约束。`AGENTS.md` 链接到本文件。

文档职责按以下顺序划分：

1. PRD 定义做什么以及验收标准。
2. ADR 记录为什么采用某项长期技术决策。
3. `CLAUDE.md` 定义所有开发活动必须遵循的原则和规范。
4. `.claude/skills/shadowing-development/SKILL.md` 定义日常开发 SOP。
5. 代码、测试、Makefile 和 scripts 是可执行事实。

当这些内容冲突时，不要自行猜测或绕过约束；先修正文档或新增 ADR。

## Product principles

Shadowing 是 macOS 本地英语跟读应用，核心闭环是：

```text
打开 MP3 → 选择并循环片段 → 同步录音 → 多 Take 对比 → 本地恢复
```

- **Local first**：音频、录音和练习数据默认只保存在本机。
- **Privacy by default**：MVP 不上传音频，不引入账号、遥测或网络依赖。
- **Native first**：优先使用 macOS 原生交互和 Apple 平台能力。
- **Audio correctness first**：同步、选区边界和录音完整性优先于视觉效果。
- **Recoverable by design**：权限、文件丢失、设备断开、磁盘失败都必须可解释、
  可恢复，不能静默丢失用户录音。
- **Scope discipline**：只实现当前 PRD 优先级，不为未确认功能预建入口或抽象。
- **Low distraction**：界面保持简洁，波形与练习操作始终是视觉和交互中心。

产品需求见 `docs/prd/prd-v0.0.1-2026-07-11.md`。

## Engineering principles

### Simplicity

- 遵循 KISS 和 YAGNI；优先清楚、直接、可删除的实现。
- SOLID 用于降低耦合，不用于制造空协议、空层或只有一个实现的抽象体系。
- 只在真实替换边界、隔离边界或测试边界存在时创建协议。
- 复用稳定行为，不提前复用仍在变化的相似代码。
- 优先小而可验证的垂直切片，保持每次变更可构建、可回滚。

### Responsibility and dependency

- 每个类型只有一个主要变化原因。
- UI、状态协调、领域规则、平台能力和持久化职责明确分离。
- 高层策略依赖协议和领域值，不依赖数据库、音频引擎或生成代码。
- 不以 singleton 或全局可变状态规避依赖注入。
- 新 Swift 文件以 300–500 行为软上限；超过时先检查职责是否混合。

### Correctness and failure handling

- 用显式状态和合法状态转换描述加载、播放、录音、保存和恢复流程。
- 不用多个无关 boolean 推导关键状态。
- 错误必须保留操作上下文并提供恢复动作；禁止空 `catch`。
- 禁止用 `try?` 吞掉音频、文件、数据库或 migration 失败。
- 资源获取与释放必须成对：task cancellation、audio tap、临时文件、
  security-scoped access 和 transaction 都要有明确清理路径。
- 性能判断必须基于测量，不凭直觉引入缓存、并行或跨语言实现。

### Maintainability

- 命名表达领域语义，不暴露底层框架细节。
- 注释解释不明显的原因、约束和权衡，不复述代码。
- 公共行为只有一个事实来源；命令统一通过 Makefile/scripts。
- 依赖应尽量少、固定版本，并有明确产品价值和维护责任。
- 重构不得混入无关功能变更；功能变更不得顺手扩大范围。

## Architecture

当前架构由 `docs/adr/README.md` 中的 Accepted ADR 决定：

- SwiftUI + Swift 6，最低 macOS 15。
- AVFoundation/Core Audio 负责播放、录音、权限和设备。
- GRDB/SQLite 保存结构化元数据。
- 录音和可重建的波形缓存保存在文件系统。
- MVP 不引入 Rust、UniFFI 或 cargo-swift；重新评估条件见 ADR-0010。
- `Shadowing/project.yml` 是 Xcode 工程唯一事实来源，不提交生成的 `.xcodeproj`。

依赖方向：

```text
View → ViewModel / UseCase → Domain protocol
                                  ↑
               Audio / Persistence / Services adapter
```

### Layer rules

- **View**：只渲染状态和发送 intent；不直接使用 AVFoundation、GRDB、bookmark
  或文件 I/O。
- **ViewModel/UseCase**：在 `@MainActor` 协调 UI 状态、异步任务和取消，不持有
  数据库具体类型。
- **Domain**：只包含值对象、不变量、状态转换和协议，不导入 SwiftUI、
  AVFoundation 或 GRDB。
- **Audio**：封装音频图、播放时钟、录音和波形采样，不承担 UI 或持久化职责。
- **Persistence**：实现 Domain repository/store 协议，不向外泄漏 GRDB 类型。
- **Services**：封装 security-scoped bookmark、系统权限等 Apple 平台能力。

长期改变依赖方向、模块职责、技术栈、数据模型或分发方式时，必须先新增 ADR。
Accepted ADR 只能由新 ADR supersede，不直接改写历史结论。

## Swift and concurrency

- 开启 Swift 6 strict concurrency；跨 actor 值必须满足 `Sendable`。
- UI 状态更新在 `@MainActor`；不要用 `DispatchQueue.main.async` 绕过隔离。
- 优先使用不可变 struct；只有身份或共享可变生命周期需要 class/actor。
- 明确 task 的 owner、取消时机和 actor 边界。
- 不使用 `@unchecked Sendable` 消除编译错误，除非有可证明的不变量和解释。
- 不用 sleep、固定延迟或 UI timer 修复竞态。

## Audio rules

- 使用 sample/render time 决定循环和录音边界；UI timer 只显示进度。
- 实时 callback 禁止阻塞、SQLite、同步主线程调用、密集日志和无界分配。
- 播放、录音、波形和设备路由共享明确的时钟与会话生命周期。
- 中断、route change、麦克风断开、提前停止和写入失败是正式状态。
- Take 只有在录音文件完成、可播放并成功提交后才能进入用户列表。
- 音频架构变化必须验证 5/30/60 秒选区、重复循环和实际硬件异常场景。

## Persistence and data rules

- SQLite 保存项目、选区快照、Take、最近文件和 schema version。
- 录音不存 SQLite BLOB；数据库只保存稳定相对路径和元数据。
- Take 提交顺序固定为：临时写入 → 校验 → 原子移动 → 元数据 transaction。
- migration 只向前、可重复执行、有升级测试；已经发布的 migration 不修改。
- 新字段必须可空或具有安全默认值。
- security-scoped bookmark 的创建、解析和访问生命周期留在 Swift。
- 删除和失败恢复不得产生数据库悬空引用或不可识别的录音文件。

## Testing and quality

- Domain 不变量和状态转换使用确定性单元测试。
- repository 实现共享 contract tests；schema 变化必须有 migration tests。
- 时间相关逻辑使用可注入 clock/scheduler，不用真实等待构造测试。
- 硬件音频行为无法可靠自动化时，必须保留明确的手工验收场景。
- bug 修复先添加能复现问题的测试，再修复。
- warning、lint、测试和架构校验都是门禁，不得禁用或跳过来完成任务。
- 完成实现前运行 `make check`。

## Git commit message

所有提交使用 Conventional Commits：

```text
<type>(<scope>): <中文摘要>

<中文正文>
```

规则：

- 允许 `feat`、`fix`、`docs`、`refactor`、`perf`、`test`、`build`、`ci`、
  `chore`、`style`、`revert`。
- type 和 scope 使用小写英文；scope 使用稳定模块名，如 `audio`、`practice`、
  `recording`、`persistence`、`ui`、`build`、`release`、`docs`。
- 摘要使用中文、使用动词、无句号，尽量不超过 72 个字符。
- 每个提交都包含非空中文正文，说明动机、关键行为和影响，不机械重复摘要。
- 正文不记录测试结果；验证结果放在 PR 或任务总结中。
- 一个提交表达一个逻辑目的；格式化、重构和功能变更不要无关混合。
- breaking change 使用 `type(scope)!:`，并添加 `BREAKING CHANGE:` footer。

示例：

```text
feat(audio): 增加选区循环播放时钟

以音频渲染时间控制循环边界，避免长时间练习后由界面计时器造成累计漂移。
```

## Git tag message

- 发布 tag 使用 SemVer：`vMAJOR.MINOR.PATCH`。
- 只创建 annotated tag，不使用 lightweight tag。
- tag message 面向维护者与发布追溯，必须包含版本标题、用户价值摘要和
  `CHANGELOG.md` 指引，不能只有版本号。
- tag、`CFBundleShortVersionString` 和 changelog 版本必须一致。
- `CFBundleVersion` 是递增构建号，不进入常规 tag 名。

格式：

```text
Shadowing vX.Y.Z

<一至两句中文版本摘要，说明本次发布解决的用户问题或完成的核心闭环。>

完整变更见 CHANGELOG.md。
```

## Release message

GitHub Release 文案面向用户，不是 commit 列表或开发日志：

```markdown
## 本次更新

<一句话说明版本价值。>

## 新增

- <用户可感知的新能力>

## 改进

- <用户可感知的体验或性能变化>

## 修复

- <修复的问题及影响>

## 安装说明

- <兼容性、数据迁移或首次启动注意事项；无则省略本节>
```

规则：

- 使用中文、具体、可验证的用户语言，避免“优化若干问题”等空泛表述。
- 只写已包含且已验证的行为，不承诺未来功能。
- 内部重构、CI、依赖升级通常不写，除非影响兼容性、安全或用户体验。
- breaking change、最低系统版本、数据迁移和已知问题必须显著说明。
- Release 标题使用 `Shadowing vX.Y.Z`，正文与对应 changelog 和 tag 一致。
- 不由 workflow 临时生成未经审阅的 release notes；发布前先维护 changelog。

## Commands and generated files

```bash
make setup       # 安装工具、hooks 并生成工程
make generate    # 从 project.yml 生成 Xcode 工程
make build       # 无签名 Debug build
make upgrade     # 重新构建并重启 Debug app
make test        # 运行 macOS 测试
make format      # 格式化 Swift
make lint        # 静态与架构校验
make check       # 完整质量门禁
make clean
```

禁止在文档和 CI 复制零散 `xcodebuild` 长命令；统一复用 Makefile/scripts。
不要提交 `.xcodeproj`、DerivedData、构建产物、数据库、录音、临时文件、
本地配置或 secrets。
