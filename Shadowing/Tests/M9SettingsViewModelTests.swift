import Foundation
@testable import Shadowing
import XCTest

final class M9SettingsViewModelTests: XCTestCase {
    @MainActor
    func testSettingsPersistAcrossReload() async {
        let storage = InMemoryPersistence()
        let store = InMemorySettingsStore(storage: storage)
        let devices = M9InputDeviceFake(
            devices: [AudioInputDevice(id: "mic-a", name: "USB Mic")],
            selectedID: "mic-a"
        )
        let viewModel = SettingsViewModel(
            store: store,
            inputDevicesProvider: devices,
            storageDirectory: URL(fileURLWithPath: "/tmp/Shadowing-Recordings")
        )

        await viewModel.load()
        viewModel.setCountdownSeconds(5)
        viewModel.setPlayOriginalWhileRecording(false)
        viewModel.setDefaultPlaybackRate(1.25)
        viewModel.selectInputDevice(id: "mic-a")

        await waitUntil {
            let stored = try? await store.value(for: AppSettings.storeKey, as: AppSettings.self)
            return stored?.countdownSeconds == 5
                && stored?.playOriginalWhileRecording == false
                && stored?.defaultPlaybackRate == 1.25
                && stored?.preferredInputDeviceUID == "mic-a"
        }

        let reloaded = SettingsViewModel(
            store: store,
            inputDevicesProvider: devices,
            storageDirectory: URL(fileURLWithPath: "/tmp/Shadowing-Recordings")
        )
        await reloaded.load()
        XCTAssertEqual(reloaded.settings.countdownSeconds, 5)
        XCTAssertFalse(reloaded.settings.playOriginalWhileRecording)
        XCTAssertEqual(reloaded.settings.defaultPlaybackRate, 1.25)
        XCTAssertEqual(reloaded.selectedInputDeviceID, "mic-a")
        XCTAssertEqual(reloaded.storagePath, "/tmp/Shadowing-Recordings")
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        for _ in 0 ..< 200 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not satisfied")
    }
}

private actor M9InputDeviceFake: AudioInputDeviceProviding {
    private let devices: [AudioInputDevice]
    private var selectedID: String?

    init(devices: [AudioInputDevice], selectedID: String?) {
        self.devices = devices
        self.selectedID = selectedID
    }

    func availableInputDevices() async -> [AudioInputDevice] {
        devices
    }

    func selectedInputDeviceID() async -> String? {
        selectedID
    }

    func selectInputDevice(id: String?) async throws {
        selectedID = id
    }

    func inputLevel() async -> Float {
        0.2
    }
}
