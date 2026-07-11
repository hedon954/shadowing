import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings = AppSettings.default
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedInputDeviceID: String?
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var storagePath: String
    @Published var failureMessage: String?

    private let store: any SettingsStore
    private let inputDevicesProvider: any AudioInputDeviceProviding
    private var levelTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var hasLoaded = false

    init(
        store: any SettingsStore,
        inputDevicesProvider: any AudioInputDeviceProviding,
        storageDirectory: URL
    ) {
        self.store = store
        self.inputDevicesProvider = inputDevicesProvider
        storagePath = storageDirectory.path
    }

    deinit {
        levelTask?.cancel()
        persistTask?.cancel()
    }

    func load() async {
        guard !hasLoaded else {
            await refreshDevices()
            return
        }
        hasLoaded = true
        do {
            if let stored = try await store.value(
                for: AppSettings.storeKey,
                as: AppSettings.self
            ) {
                settings = stored
            } else {
                settings = .default
            }
            if let preferred = settings.preferredInputDeviceUID {
                selectedInputDeviceID = preferred
            } else {
                selectedInputDeviceID = await inputDevicesProvider.selectedInputDeviceID()
            }
            await refreshDevices()
            startLevelMeter()
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    func setCountdownSeconds(_ value: Int) {
        guard AppSettings.supportedCountdownSeconds.contains(value) else {
            return
        }
        settings.countdownSeconds = value
        persist()
    }

    func setPlayOriginalWhileRecording(_ value: Bool) {
        settings.playOriginalWhileRecording = value
        persist()
    }

    func setDefaultPlaybackRate(_ value: Double) {
        guard AppSettings.supportedPlaybackRates.contains(value) else {
            return
        }
        settings.defaultPlaybackRate = value
        persist()
    }

    func selectInputDevice(id: String?) {
        selectedInputDeviceID = id
        settings.preferredInputDeviceUID = id
        persist()
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await inputDevicesProvider.selectInputDevice(id: id)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        levelTask?.cancel()
        levelTask = nil
    }

    private func persist() {
        let snapshot = settings
        let previous = persistTask
        persistTask = Task { [weak self, store] in
            await previous?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                try await store.set(snapshot, for: AppSettings.storeKey)
            } catch {
                self?.failureMessage = error.localizedDescription
            }
        }
    }

    private func refreshDevices() async {
        inputDevices = await inputDevicesProvider.availableInputDevices()
        if selectedInputDeviceID == nil {
            selectedInputDeviceID = await inputDevicesProvider.selectedInputDeviceID()
        }
    }

    private func startLevelMeter() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                inputLevel = await inputDevicesProvider.inputLevel()
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
        }
    }
}
