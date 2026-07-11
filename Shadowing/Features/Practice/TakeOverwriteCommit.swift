import Foundation

struct PreparedTakeCommit: Sendable {
    let fileURL: URL
    let region: PracticeRegion
    let duration: TimeInterval
}

enum TakeOverwriteCommit {
    static func prepare(
        newRecordingURL: URL,
        duration: TimeInterval,
        context: PendingRecordingContext,
        sourceDuration: TimeInterval,
        fileStore: any RecordingFileStore
    ) throws -> PreparedTakeCommit {
        guard context.replacesExisting,
              let previousPath = context.previousRelativePath,
              let previousStart = context.previousRegionStart,
              let previousDuration = context.previousDuration
        else {
            let region = try resolvedRegion(
                context: context,
                duration: duration,
                sourceDuration: sourceDuration
            )
            return PreparedTakeCommit(
                fileURL: newRecordingURL,
                region: region,
                duration: duration
            )
        }

        let plan = TakeOverwritePlan.planning(
            previousStart: previousStart,
            previousDuration: previousDuration,
            newStart: context.region.start,
            newDuration: duration
        )
        let region = try PracticeRegion.takeAlignment(
            id: context.region.id,
            start: plan.resultStart,
            end: plan.resultStart + plan.resultDuration,
            sourceDuration: sourceDuration
        )
        guard plan.needsSplice else {
            return PreparedTakeCommit(
                fileURL: newRecordingURL,
                region: region,
                duration: plan.resultDuration
            )
        }

        let existingURL = try fileStore.audioURL(relativePath: previousPath)
        let spliceURL = try fileStore.temporaryTakeURL(id: UUID())
        try TakeAudioSplicer.merge(
            existingURL: existingURL,
            newRecordingURL: newRecordingURL,
            plan: plan,
            outputURL: spliceURL
        )
        try? fileStore.discardTemporaryTake(at: newRecordingURL)
        return PreparedTakeCommit(
            fileURL: spliceURL,
            region: region,
            duration: plan.resultDuration
        )
    }

    private static func resolvedRegion(
        context: PendingRecordingContext,
        duration: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> PracticeRegion {
        let end = min(context.region.start + duration, sourceDuration)
        return try PracticeRegion.takeAlignment(
            id: context.region.id,
            start: context.region.start,
            end: end,
            sourceDuration: sourceDuration
        )
    }
}
