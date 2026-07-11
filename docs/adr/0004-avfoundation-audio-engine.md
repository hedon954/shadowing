# ADR-0004: AVFoundation 音频引擎与同步模型

- Status: Proposed
- Date: 2026-07-11

## Context

选区循环、变速播放、可选的录音时原音播放，以及 Take 独立循环，都依赖统一且
可观测的时间基准。多个独立 player 容易造成漂移，UI timer 也不能作为录音
边界的真实时钟。

## Decision

- 以单个 `AVAudioEngine` 音频图作为练习会话的实时核心。
- 使用 player node 调度原音；独立 take player 调度 Take 文件片段；麦克风
  input node tap 负责录音与实时峰值入队。
- 选区起止转换为采样帧，并以渲染时间而不是 UI timer 决定循环边界与自动停止。
- Original 循环与 Take 循环相互独立：Original 使用练习选区；Take 使用该轨
  自己的选区（映射为 Take 本地时间），无选区则单次播完即停。
- 循环播放中更新选区时，引擎按新区间重新调度；若当前播放头仍在新区间内则
  从该位置继续，否则从新区间起点重播。
- UI 播放头是音频时钟的投影；UI 更新频率与音频回调解耦。
- 录音从当前播放头写到文件末尾或用户停止；写临时文件，完成并校验后原子移动
  到正式 Take 路径。默认不播放原音；设置开启时才同步播放。
- 实时回调禁止数据库、主线程同步等待和无界内存分配。

在 Phase 1 Spike 通过前，本 ADR 保持 Proposed。

## Consequences

同步语义集中，原音与 Take 可共用会话时钟，但 AVAudioEngine 的路由变化和
变速节点会增加实现复杂度。Take 循环通过 segment 重排调度，避免跨格式
`scheduleBuffer` 循环。

## Verification

- 5、30、60 秒选区各循环 20 次，无可感知边界累积漂移。
- 循环中拖动选区边界后，下一次循环边界与新选区一致。
- 自动停止误差目标不超过一个 render buffer。
- 录音时设备断开不会留下已登记但不可播放的 Take。
- Take 有选区时只循环选区；无选区时播完停止。
