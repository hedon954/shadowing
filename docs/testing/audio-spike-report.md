# M2 Audio Spike Report

- Date: 2026-07-11
- Environment: Apple Silicon macOS, Xcode macOS 26.5 SDK, Swift 6 strict concurrency
- Scope: deterministic scheduling, offline waveform processing, bounded recording writer,
  and compilation of the AVFoundation practice engine

This report records automated evidence only. It does not change ADR-0004 or ADR-0005 from
Proposed to Accepted.

## Automated results

### Frame timing and region loops

`AudioTimingTests` exercises 44.1 kHz and 48 kHz source clocks:

- 5, 30, and 60 second regions each run through 20 loop boundaries.
- Every source boundary is calculated from the original region start and integer frame
  length. Measured cumulative source-frame drift is **0 frames**.
- Output boundaries are checked at 0.5x, 0.75x, 1.0x, 1.25x, and 1.5x against a direct
  origin-based calculation. Rounding error is at most **0.5 output frame**, or
  **10.42 microseconds at 48 kHz**.
- Frame/time round trips at 44.1, 48, and 96 kHz remain within half a source frame.
- A mid-region rate change preserves the exact source start and end frames and recalculates
  the remaining output duration instead of accumulating prior rounded durations.

These are mathematical scheduler results. They do not measure DAC output latency or an
audible gap at the `AVAudioPlayerNode` loop seam.

### Waveform generation and cache

Tests generate temporary mono Float32 CAF fixtures at 48 kHz; no audio fixture is stored in
the repository.

- A two-second, 0.8-amplitude sine fixture produced normalized peaks at 256, 1,024, and
  4,096 frames per peak.
- Peak counts were 375, 94, and 24 respectively, including the final partial bucket.
- Maximum measured peak was within 0.01 of the generated 0.8 amplitude.
- The final `make check` run completed this generation test in **0.055 seconds**. This is a
  test-run observation, not a stable performance budget.
- A generated 20-second input was cancelled successfully; the cancellation test completed
  in **0.144 seconds**, including fixture creation.
- Cache round-trip, source modification invalidation, and cache removal/rebuild behavior
  passed.

The generator streams decoded PCM through `AVAssetReader` and vDSP bucket accumulators; it
does not retain full decoded PCM.

### Recording writer

The recording pipeline test copied four generated 1,024-frame microphone-style buffers into
an eight-buffer bounded stream, wrote a temporary CAF off the input callback, and emitted
four peaks:

- Written duration: **4,096 / 48,000 = 85.333 milliseconds**.
- Dropped buffers: **0**.
- Peak error from the generated 0.6 signal: less than **0.001**.
- Test duration in the final `make check` run: **0.009 seconds**.

Queue overrun is treated as a failed recording and the temporary file is removed instead of
being exposed as a valid Take.

### Quality gate snapshot

The M2 spike landed with **34 tests**. The P0 implementation gate now expects the full
suite under `make check`; see `docs/testing/p0-acceptance-checklist.md` for the current
acceptance split between automated and hardware evidence.

## Implementation boundaries verified by inspection

- `PracticeAudioEngine` owns `AVAudioEngine`, `AVAudioPlayerNode`, and
  `AVAudioUnitTimePitch`; Domain exposes only Foundation value types and commands/events.
- Playback head updates are projections of player render/sample time, not loop boundaries.
- The input tap performs only bounded PCM copying, vDSP peak calculation, and bounded
  stream publication. File writes run on one background writer task.
- No database access or synchronous main-thread dispatch occurs in an audio callback.
- Recording stops on manual request, scheduled region completion, or engine configuration
  change, and emits route/interruption/failure events.

## Required hardware and long-file validation

The following evidence is still required before ADR-0004 or ADR-0005 can be considered for
acceptance:

1. Play real MP3 files and listen to 5, 30, and 60 second regions for 20 loops at every
   supported rate; capture render timestamps and verify the seam is gap-free.
2. Measure region-end automatic recording stop against render-buffer size on built-in input,
   a USB microphone, Bluetooth output, and wired headphones.
3. Disconnect and reconnect the active microphone and output route while playing and while
   recording; verify no invalid Take is registered and recovery is actionable.
4. Verify manual early stop both below and above the 0.5-second valid-Take threshold.
5. With wired headphones, verify original and recorded tracks share the intended start and
   assess Together-mode latency when that mode is wired to product UI.
6. Import at least one 60-minute MP3 and record wall time, peak resident memory, cache size,
   cancellation latency, and waveform resize/render smoothness.
7. Exercise microphone permission denial and subsequent enablement in System Settings.

ADR-0004 and ADR-0005 intentionally remain **Proposed** until these hardware and 60-minute
file measurements are completed.
