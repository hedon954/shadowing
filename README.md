# Shadowing

Shadowing is a local-first macOS app for practicing English pronunciation by looping a
selected part of an MP3, recording a take, and comparing both tracks on one timeline.

The repository currently contains the MVP product definition, architecture decisions, and
the development foundation for the native app.

## MVP stack

- SwiftUI and Swift 6
- AVFoundation/Core Audio for playback and recording
- GRDB/SQLite for project metadata
- Local files for recordings and waveform caches
- XcodeGen as the Xcode project source of truth

Rust, UniFFI, and cargo-swift are intentionally excluded from the MVP. Persistence is
defined behind Swift protocols so a future UniFFI adapter can be introduced without
coupling Views or Domain types to it. See
[ADR-0010](docs/adr/0010-rust-uniffi-adoption-threshold.md).

## Requirements

- macOS 15 or newer
- Xcode with the macOS SDK
- Homebrew

## Development

```bash
make setup
make build
make test
make check
```

`make setup` installs the tools declared in `Brewfile`, installs pre-commit hooks, and
generates `Shadowing/Shadowing.xcodeproj`. The generated project is not committed; edit
`Shadowing/project.yml` instead.

## Documentation

- [MVP PRD](docs/prd/prd-v0.0.1-2026-07-11.md)
- [ADR roadmap and index](docs/adr/README.md)
- [Engineering guide](CLAUDE.md)
- [P0 acceptance checklist](docs/testing/p0-acceptance-checklist.md)
- [Audio spike report](docs/testing/audio-spike-report.md)
- [Initial UI references](assets/img/)

## Source layout

```text
Shadowing/
├── App/             App entry and composition
├── Domain/          Models, rules, and persistence contracts
├── Features/        Feature Views and ViewModels
├── Audio/           AVFoundation and waveform implementations
├── Persistence/     GRDB and file-store implementations
├── Services/        Apple platform service adapters
└── Tests/           Unit, contract, and migration tests
```

Run `make help` for all supported commands. Local and CI quality gates share
`make check`.
