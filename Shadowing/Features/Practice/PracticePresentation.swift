import Foundation

/// What the toolbar subtitle says about the open practice file.
enum PracticeHeaderStatus: Equatable {
    case takes(count: Int, lastPracticed: Date?)
    case checkingMicrophone
    case countingDown(takeNumber: Int, remainingSeconds: Int)
    case recording(takeNumber: Int)
    case saving(takeNumber: Int)

    var isRecordingActivity: Bool {
        switch self {
        case .takes:
            false
        case .checkingMicrophone, .countingDown, .recording, .saving:
            true
        }
    }
}

extension PracticeViewModel {
    /// Number of the take being recorded. Recording over a selected take keeps that take's number.
    var recordingTakeNumber: Int {
        if let recordingContext {
            return recordingContext.sequence
        }
        if let activeTake {
            return activeTake.sequence
        }
        return (takes.map(\.sequence).max() ?? 0) + 1
    }

    var lastPracticedAt: Date? {
        takes.map(\.createdAt).max()
    }

    var headerStatus: PracticeHeaderStatus {
        switch recordingPresentation {
        case .idle:
            .takes(count: takes.count, lastPracticed: lastPracticedAt)
        case .checkingPermission:
            .checkingMicrophone
        case let .countingDown(remainingSeconds):
            .countingDown(takeNumber: recordingTakeNumber, remainingSeconds: remainingSeconds)
        case .recording:
            .recording(takeNumber: recordingTakeNumber)
        case .finalizing:
            .saving(takeNumber: recordingTakeNumber)
        }
    }

    /// The red "Recording" row at the top of the takes list.
    var showsLiveTakeRow: Bool {
        switch recordingPresentation {
        case .countingDown, .recording, .finalizing:
            true
        case .idle, .checkingPermission:
            false
        }
    }

    /// Longest take, so mini waveforms in the takes list share one time scale.
    var longestTakeDuration: TimeInterval {
        max(takes.map(\.duration).max() ?? 0, recordingElapsed, 1)
    }

    var isTimelineZoomed: Bool {
        timelineViewport.duration < project.duration - 0.01
    }
}
