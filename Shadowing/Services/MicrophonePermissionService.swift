@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation

actor SystemMicrophonePermissionService: MicrophonePermissionService {
    /// Reads the current access without ever showing the system prompt.
    @Sendable
    static func currentStatus() -> MicrophonePermissionState {
        permissionState(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func authorizationStatus() -> MicrophonePermissionState {
        Self.currentStatus()
    }

    func requestAuthorization() async -> MicrophonePermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if granted {
            return .authorized
        }
        return authorizationStatus()
    }

    func openSystemSettings() async {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private static func permissionState(
        for status: AVAuthorizationStatus
    ) -> MicrophonePermissionState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .authorized
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }
}

struct ContinuousRecordingCountdownClock: RecordingCountdownClock {
    func waitForNextSecond() async throws {
        try await Task.sleep(for: .seconds(1))
    }
}
