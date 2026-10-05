import AppKit
import Foundation

extension PracticeViewModel {
    /// Re-reads microphone access whenever the app becomes active, e.g. after the user allowed
    /// access in System Settings. Recording then works without restarting Shadowing.
    func observeAppActivation() {
        guard let recordingDependencies, appActivationTask == nil else {
            return
        }
        let activations = recordingDependencies.appActivationCenter
            .notifications(named: NSApplication.didBecomeActiveNotification)
            .map { _ in () }
        appActivationTask = Task { [weak self] in
            for await _ in activations {
                guard !Task.isCancelled else {
                    return
                }
                await self?.refreshMicrophonePermission()
            }
        }
    }

    /// Reads access without prompting. Once access is granted, a leftover "Microphone Access
    /// Required" alert is dismissed; while access is still missing, R keeps showing that alert.
    func refreshMicrophonePermission() async {
        guard let recordingDependencies else {
            return
        }
        let permission = await recordingDependencies.permissions.authorizationStatus()
        microphonePermission = permission
        if permission == .authorized {
            microphonePermissionPrompt = nil
        }
    }
}
