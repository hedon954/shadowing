# ADR-0012: 录音总是新增 Take，不再覆盖选中的 Take

- Status: Accepted
- Date: 2026-10-05
- Owners: Shadowing maintainers
- Supersedes: PRD v0.0.1 §10.6“覆盖重录”

## Context

原 PRD §10.6 规定：选中某条 Take 后再录音，会从播放头开始覆盖该 Take 的重叠部分，把新旧
音频按原音时间轴拼接（空隙写入静音），提交后仍是同一 Take。

v8 的核心用法是把多遍跟读和原音、以及彼此对比。覆盖会悄悄毁掉用户想比较的旧录音；拼接后的
文件也只能保存一个对齐偏移，旧片段和新片段的偏移不同，只能近似。

## Decision

- 点击 Record 总是新建 Take：新 id、sequence 为现有最大值 + 1、显示在列表最上方。
- 选中的 Take 不受影响：音频文件、数据库记录和 `Recordings/<take id>.json` 偏移都不变。
- 录完后新 Take 成为选中项（“正在对比”）。
- 删除覆盖相关代码：`TakeOverwritePlan`、`TakeAudioSplicer`、`TakeOverwriteCommit`
  及其测试，以及“覆盖录音的偏移近似”。
- 持久化层 `commit(..., replaceExisting:)` 接口保留（仓库契约仍覆盖它），练习界面只用新增。

## Consequences

### Positive

- 旧录音不会被意外覆盖，多遍对比可靠。
- 每条 Take 都是一次连续录音，偏移测量精确对应整条文件。
- 录音流程更简单，少一条拼接音频的失败路径。

### Negative

- Take 数量增长更快，需要用户自己删除不想要的录音。
- 无法只重录一句并补进旧 Take。

## Verification

- `M6ViewModelTests.testSelectedTakeRecordAddsNewTakeAndKeepsTheSelectedOne`：选中 Take 时
  录音新增一条，旧 Take 记录和音频字节不变，新 Take 被选中。
- `RecordingAlignmentTests.testRecordingWithATakeSelectedKeepsThatTakesOffset`：第二次录音
  写自己的偏移文件，第一条的偏移不变。
