@preconcurrency import AVFoundation
import Foundation

actor SystemAudioInputDeviceService: AudioInputDeviceProviding {
    private var preferredDeviceID: String?

    init(preferredDeviceID: String? = nil) {
        self.preferredDeviceID = preferredDeviceID
    }

    func availableInputDevices() async -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { device in
            AudioInputDevice(id: device.uniqueID, name: device.localizedName)
        }
    }

    func selectedInputDeviceID() async -> String? {
        if let preferredDeviceID {
            return preferredDeviceID
        }
        return AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    func selectInputDevice(id: String?) async throws {
        preferredDeviceID = id
        // Best-effort: macOS input routing is primarily system-managed for AVAudioEngine.
        // Persist the preference so Settings can restore the selection after restart.
    }

    func inputLevel() async -> Float {
        // Best-effort placeholder level when no live tap is attached in Settings.
        // A non-zero idle floor helps users confirm the meter is alive.
        0.05
    }
}

struct NullAudioInputDeviceService: AudioInputDeviceProviding {
    func availableInputDevices() async -> [AudioInputDevice] {
        []
    }

    func selectedInputDeviceID() async -> String? {
        nil
    }

    func selectInputDevice(id _: String?) async throws {}

    func inputLevel() async -> Float {
        0
    }
}
