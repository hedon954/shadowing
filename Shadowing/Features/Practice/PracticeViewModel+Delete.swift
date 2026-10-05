import Foundation

/// ⌘⌫ moves a take to the Trash (audio and offset file) and removes its row, with no
/// confirmation; ⌘Z puts the files back and re-inserts the same row.
extension PracticeViewModel {
    func requestDeleteTake(_ take: Take? = nil) {
        guard !controlsLocked, let target = take ?? activeTake else {
            return
        }
        pauseTakePlaybackIfNeeded()
        Task { [weak self] in
            await self?.deleteTake(target)
        }
    }

    func deleteTake(_ take: Take) async {
        guard let dependencies = recordingDependencies else {
            show(PracticeRecordingError.unavailable)
            return
        }
        do {
            let urls = try [dependencies.fileStore.audioURL(relativePath: take.relativeAudioPath)]
                + [dependencies.alignment?.fileURL(for: take.id)].compactMap(\.self)
            let trasher = dependencies.trash
            let trashed = try await Task.detached(priority: .userInitiated) {
                try TakeTrash.trash(urls, take: take, using: trasher)
            }.value
            do {
                try await dependencies.takes.deleteTake(id: take.id)
            } catch {
                try? TakeTrash.restore(trashed)
                throw error
            }
            var undoable = trashed
            undoable.wasKept = project.keptTakeID == take.id
            undoable.wasSelected = activeTake?.id == take.id
            registerUndoDelete(undoable)
            await forgetDeletedTake(take)
        } catch {
            show(error)
        }
    }

    /// Undo: in one transaction, the same row (same id and fields) goes in first, then the files
    /// move back from where the Trash put them. A failed insert moves nothing; a failed move
    /// rolls the row back and returns any moved file to the Trash. Kept and selected come back too.
    func undoDeleteTake(_ trashed: TrashedTake) async {
        guard let dependencies = recordingDependencies else {
            return
        }
        do {
            try TakeTrash.checkStillInTrash(trashed)
            do {
                try await dependencies.takes.restoreTake(trashed.take) {
                    try TakeTrash.restore(trashed)
                }
            } catch {
                throw TakeTrashError.couldNotRestore(sequence: trashed.take.sequence)
            }
            await refreshTakes()
            await reapplyState(of: trashed)
        } catch {
            show(error)
        }
    }

    /// A new take may reuse a deleted take's number, so its Undo can no longer put it back.
    func forgetUndoDelete() {
        undoManager?.removeAllActions(withTarget: self)
    }

    private func reapplyState(of trashed: TrashedTake) async {
        guard let restored = takes.first(where: { $0.id == trashed.take.id }) else {
            return
        }
        if trashed.wasKept {
            project.keptTakeID = restored.id
        }
        if trashed.wasSelected || activeTake == nil {
            await focusTake(restored, preferExistingViewport: true)
            await loadTakeWaveform(for: restored)
            return
        }
        do {
            try await projects.save(project)
        } catch {
            show(error)
        }
    }

    private func registerUndoDelete(_ trashed: TrashedTake) {
        guard let undoManager else {
            return
        }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            Task { @MainActor in
                await model.undoDeleteTake(trashed)
            }
        }
        undoManager.setActionName(String(localized: "Delete Take \(trashed.take.sequence)"))
        undoManager.endUndoGrouping()
    }

    private func forgetDeletedTake(_ take: Take) async {
        takeOffsets[take.id] = nil
        takeWaveforms[take.id] = nil
        takeLoopSelections[take.id] = nil
        if project.keptTakeID == take.id {
            project.keptTakeID = nil
        }
        if playingTakeID == take.id {
            playingTakeID = nil
            isPlaying = false
        }
        await refreshTakes()
        if let next = takes.max(by: { $0.createdAt < $1.createdAt }) {
            await focusTake(next, preferExistingViewport: true)
            await loadTakeWaveform(for: next)
            return
        }
        activeTake = nil
        selectedTakePeaks = []
        project.selectedTakeID = nil
        recordingNotice = nil
        playhead = min(max(project.playhead, 0), project.duration)
        if let region {
            timelineViewport = .fitting(region, sourceDuration: project.duration)
        } else {
            timelineViewport = .full(sourceDuration: project.duration)
        }
        do {
            try await projects.save(project)
        } catch {
            show(error)
        }
    }
}
