# ADR-0005: 波形生成、缓存与渲染

- Status: Proposed
- Date: 2026-07-11

## Context

应用需要展示长 MP3 的完整波形、可拖动选区和实时录音波形。逐帧绘制原始
PCM 会造成内存和渲染压力，长文件每次打开都重新解码也会影响启动体验。

## Decision

- 使用 AVAssetReader 离线读取 PCM，使用 Accelerate/vDSP 聚合归一化峰值。
- 缓存多分辨率、与源文件指纹关联的 peak 数据；不缓存完整解码 PCM。
- SwiftUI Canvas 只绘制当前尺寸所需的 peak 数量。
- 实时录音使用有界环形缓冲生成预览；Take 完成后生成稳定缓存。
- 源文件大小或修改时间变化时使缓存失效。

在长音频性能 Spike 通过前，本 ADR 保持 Proposed。

## Consequences

首次导入需要后台预处理，但后续打开和窗口缩放成本较低。

## Verification

- 使用至少 60 分钟 MP3 测量导入耗时、峰值内存和窗口缩放流畅度。
- 生成任务可取消，失败不阻止音频直接播放。
- 缓存删除后可以无数据损失地重建。
