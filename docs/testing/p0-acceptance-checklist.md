# P0 Acceptance Checklist

- Date: 2026-07-11
- Scope: PRD §17 P0 and §18 MVP acceptance flow
- Automated gate: `make check`

This checklist separates automated evidence from hardware/manual verification.
ADR-0004 and ADR-0005 remain Proposed until the hardware matrix below is completed.

## Automated evidence

| Area | Evidence | Status |
| --- | --- | --- |
| Domain region rules | `PracticeRegionTests` | Automated |
| Session state machine | `PracticeSessionStateMachineTests` | Automated |
| Persistence contracts | `RepositoryContractTests`, `AppDatabaseTests` | Automated |
| Recording file transaction | `RecordingFileStoreTests` | Automated |
| Audio timing / loops | `AudioTimingTests` | Automated math only |
| Waveform generation | `WaveformProcessingTests` | Automated fixtures |
| Recording writer | `RecordingPipelineTests` | Automated fixtures |
| Open / play / region | `M3*`, `M4*` ViewModel tests | Automated with fakes |
| Recording workflow | `M5ViewModelTests` | Automated with fakes |
| Compare / multi Take | `M6ViewModelTests` | Automated with fakes |
| Recovery / relocate | `M7PersistenceTests`, `M7ViewModelTests` | Automated with fakes |
| Architecture / lint / build | `make check` | Required before RC |

## PRD §18 manual flow

Run on a short (1–3 min), medium (10–20 min), and long (≥60 min) MP3 when possible.

1. [ ] Launch the app.
2. [ ] Open a local MP3 via Choose File.
3. [ ] Confirm the full waveform appears.
4. [ ] Play audio.
5. [ ] Click the waveform to seek.
6. [ ] Select a 5–10 second region.
7. [ ] Confirm loop is enabled.
8. [ ] Confirm only the selected region repeats.
9. [ ] Change playback speed.
10. [ ] Start recording.
11. [ ] Complete the countdown.
12. [ ] Confirm original playback and recording start together.
13. [ ] Confirm automatic stop at the region end.
14. [ ] Confirm the recording waveform appears.
15. [ ] Play Original only.
16. [ ] Play My Take only.
17. [ ] Re-record.
18. [ ] Confirm Take 2 is created and Take 1 remains.
19. [ ] Switch between Takes.
20. [ ] Delete one Take.
21. [ ] Quit the app.
22. [ ] Relaunch the app.
23. [ ] Reopen the same project from recent files.
24. [ ] Confirm region and remaining Takes are restored.

## Extra P0 edge cases

- [ ] 0.5 second region is accepted; shorter selection is rejected.
- [ ] 60 second region is accepted; longer selection is rejected.
- [ ] Drag-and-drop open works.
- [ ] Unsupported / missing / permission-denied files show recoverable errors.
- [ ] Recording leave confirmation offers Stop and Close / Continue.
- [ ] Source MP3 moved: Locate File restores access without losing Takes.
- [ ] Force-quit during practice still restores saved region/Takes after relaunch.
- [ ] Window resize keeps waveform and controls usable.
- [ ] Accessibility labels exist for transport, region, record, and compare controls.

## Hardware matrix

| Scenario | Built-in mic | Headphones | External USB mic | Notes |
| --- | --- | --- | --- | --- |
| 5s loop × 20 | [ ] | [ ] | [ ] | Listen for seam drift |
| 30s loop × 20 | [ ] | [ ] | [ ] | |
| 60s loop × 20 | [ ] | [ ] | [ ] | |
| Sync record + auto stop | [ ] | [ ] | [ ] | |
| Early stop recording | [ ] | [ ] | [ ] | |
| Mic unplug while recording | [ ] | n/a | [ ] | No invalid Take |
| Route / sleep interruption | [ ] | [ ] | [ ] | Explicit recovery |
| Original / My Take compare | [ ] | [ ] | [ ] | Shared start feel |
| 60 min MP3 first waveform | [ ] | n/a | n/a | Record import time / memory |

## Known limitations for P0 RC

- A/B, Together, Keep This Take, Recordings page, Settings page, and full shortcut set are P1.
- ADR-0004/0005 stay Proposed until hardware matrix rows are checked.
- Device latency calibration is P2 and intentionally absent.
- Sentence text / waveform zoom / dark mode are P2 and intentionally absent.

## Release candidate exit

- [ ] `make check` green on a clean checkout.
- [ ] PRD §18 checklist completed on at least one real MP3 with headphones.
- [ ] Hardware matrix critical rows completed for built-in mic and headphones.
- [ ] No generated project, recordings, databases, or secrets are committed.
- [ ] Known limitations documented above.
