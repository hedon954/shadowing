# ADR-0004: AVFoundation 音频引擎与同步模型

- Status: Proposed
- Date: 2026-07-11

## Context

选区循环、变速播放、原音与麦克风同步录制、A/B 和 Together 都依赖统一且
可观测的时间基准。多个独立 player 容易造成漂移，UI timer 也不能作为录音
边界的真实时钟。

## Decision

- 以单个 `AVAudioEngine` 音频图作为练习会话的实时核心。
- 使用 player node 调度原音；麦克风 input node tap 负责录音与实时峰值。
- 选区起止转换为采样帧，并以渲染时间而不是 UI timer 决定自动停止。
- UI 播放头是音频时钟的投影；UI 更新频率与音频回调解耦。
- 录音写临时文件，完成并校验后原子移动到正式 Take 路径。
- 实时回调禁止数据库、主线程同步等待和无界内存分配。

在 Phase 1 Spike 通过前，本 ADR 保持 Proposed。

## Consequences

同步语义集中、Together 易于扩展，但 AVAudioEngine 的路由变化和变速节点会
增加实现复杂度。

## Verification

- 5、30、60 秒选区各循环 20 次，无可感知边界累积漂移。
- 自动停止误差目标不超过一个 render buffer。
- 录音时设备断开不会留下已登记但不可播放的 Take。
- 使用耳机时 Together 与单轨播放保持共同起点。
