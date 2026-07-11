---
name: shadowing-development
description: Applies Shadowing's project-wide development SOP and engineering constraints. Use when implementing, fixing, refactoring, or reviewing any Shadowing product code, tests, persistence, audio behavior, or SwiftUI feature.
---

# Shadowing Development SOP

Use this workflow for every product-code change. `CLAUDE.md` is the command and convention
reference; the PRD defines product scope; ADRs define accepted technical boundaries.

## 1. Establish the change contract

1. Read the relevant PRD section and acceptance criteria.
2. Read `docs/adr/README.md` and the ADRs affected by the change.
3. Identify the user-visible success path, failure states, and state that must survive restart.
4. State which layer owns each responsibility before editing.
5. If the change contradicts an Accepted ADR or introduces a long-lived dependency, stop and
   create a new ADR. Do not silently change architecture in implementation.

Keep work inside the current PRD priority. Do not add speculative AI, network, account,
cross-platform, or Rust infrastructure.

## 2. Preserve dependency direction

```text
View → ViewModel/use case → Domain protocol
                              ↑
            Audio/Persistence/Services adapter
```

- Views render state and emit intents. They do not access AVFoundation, GRDB, bookmarks,
  or files.
- `@MainActor` ViewModels coordinate observable UI state and cancellation.
- Domain owns values, invariants, state transitions, and repository/store protocols.
- Audio, Persistence, and Services implement platform/I/O boundaries without leaking their
  concrete framework types inward.
- Add a protocol only for a real replacement, isolation, or test boundary.

Prefer a thin vertical slice over creating all layers for a future feature.

## 3. Implement behavior as explicit state

- Model asynchronous workflows with named states; do not infer recording/loading/error state
  from unrelated booleans.
- Define legal transitions and make invalid actions no-ops or typed errors.
- Keep one source of truth for playhead, selected region, active Take, and kept Take.
- Make cancellation and cleanup explicit for tasks, security-scoped access, audio taps,
  temporary files, and database transactions.
- Preserve actionable error context and map it to a recoverable user action.
- Keep Swift concurrency isolation explicit; values crossing actors must be `Sendable`.

## 4. Apply boundary-specific invariants

### Real-time audio

- Use sample/render time for loop and recording boundaries; UI timers only display progress.
- Never block, access SQLite, log repeatedly, or allocate without a fixed bound in callbacks.
- Handle interruption, route removal, early stop, permission denial, and write failure.

### Persistence and files

- Store metadata in SQLite and recording/cache payloads as files using stable relative paths.
- Write a Take as: temporary file → validate → atomic move → metadata transaction.
- Migrations are forward-only, repeatable, and tested; shipped migrations are immutable.
- Keep security-scoped bookmark creation/resolution in Swift and balance every access scope.

### SwiftUI

- Match native macOS interaction first; avoid custom controls where system behavior suffices.
- Keep the waveform and primary controls usable during window resizing.
- Add accessibility labels and keyboard behavior without firing shortcuts during text input.

## 5. Verify in increasing scope

1. Add or update the narrowest deterministic test first:
   - Domain invariant/state transition → unit test.
   - Repository/schema → contract and migration tests.
   - Audio scheduling → injected clock/scheduler test plus manual hardware scenario.
2. Run the nearest formatter/linter/test while iterating.
3. Run `make check` before declaring completion.
4. For audio changes, manually test applicable 5/30/60-second regions, repeated loops,
   early stop, interruption, route removal, and restart recovery.
5. Update PRD only for product decisions and ADR only for durable architecture decisions;
   do not use either as an implementation diary.

## Definition of done

- Acceptance criteria and failure states are implemented.
- Layer boundaries and actor isolation remain intact.
- Persistence/restart behavior is defined where relevant.
- Tests cover deterministic behavior and migrations.
- No warnings, disabled checks, generated projects, recordings, databases, or secrets enter Git.
- `make check` passes.
