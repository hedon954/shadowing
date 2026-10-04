import AppKit
@testable import Shadowing
import SwiftUI
import XCTest

/// Renders views into PNGs for design review. Runs only when `SHADOWING_SNAPSHOT_DIR` is set
/// (pass `TEST_RUNNER_SHADOWING_SNAPSHOT_DIR=<folder>` to xcodebuild). Uses an off-screen window
/// and `cacheDisplay`, so no screen recording permission is involved.
@MainActor
enum SnapshotSupport {
    static let windowSize = CGSize(width: 1180, height: 720)

    static func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["SHADOWING_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SHADOWING_SNAPSHOT_DIR to render snapshots.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var languageSuffix: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    static func render(
        _ view: some View,
        name: String,
        size: CGSize = windowSize,
        settle: Duration = .milliseconds(900),
        toolbarStyle: NSWindow.ToolbarStyle = .automatic,
        prepare: @MainActor () async -> Void = {}
    ) async throws {
        let directory = try outputDirectory()
        for dark in [false, true] {
            let window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.toolbarStyle = toolbarStyle
            window.contentViewController = NSHostingController(rootView: view)
            window.setContentSize(size)
            window.setFrameOrigin(CGPoint(x: -30000, y: -30000))
            window.orderFrontRegardless()
            window.makeKey()
            await prepare()
            try await Task.sleep(for: settle)
            guard let frameView = window.contentView?.superview else {
                window.close()
                XCTFail("No window content to render for \(name)")
                return
            }
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()
            let file = directory.appendingPathComponent(
                "\(name)-\(languageSuffix)-\(dark ? "dark" : "light").png"
            )
            try png(of: frameView, scale: window.backingScaleFactor).write(to: file)
            window.orderOut(nil)
            window.close()
        }
    }
}

extension SnapshotSupport {
    private static let windowServerLayerNames: Set<String> = [
        "CABackdropLayer", "CAPortalLayer", "SDFLayer", "CASDFLayer", "SDFPortalLayer"
    ]

    private static func windowServerLayers(in layer: CALayer) -> [CALayer] {
        if !layer.isHidden, windowServerLayerNames.contains(String(describing: type(of: layer))) {
            return [layer]
        }
        return (layer.sublayers ?? []).flatMap(windowServerLayers(in:))
    }

    /// Vibrant text uses blend filters that `render(in:)` can't apply; it would draw black.
    private static func filteredLayers(in layer: CALayer) -> [CALayer] {
        let own = layer.compositingFilter == nil ? [] : [layer]
        return own + (layer.sublayers ?? []).flatMap(filteredLayers(in:))
    }

    /// Draws the window's layer tree (toolbar, sidebar and content) into a bitmap.
    static func png(of view: NSView, scale: CGFloat) throws -> Data {
        let size = view.bounds.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.scaleBy(x: scale, y: scale)
        var background = NSColor.windowBackgroundColor.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        let root = try XCTUnwrap(view.layer)
        // Glass and backdrop layers are composited by the window server; `render(in:)` would
        // paint them as opaque sheets over the sidebar, so they are hidden while drawing.
        let hidden = windowServerLayers(in: root)
        hidden.forEach { $0.isHidden = true }
        let filtered = filteredLayers(in: root).map { ($0, $0.compositingFilter) }
        filtered.forEach { $0.0.compositingFilter = nil }
        root.render(in: context)
        filtered.forEach { $0.0.compositingFilter = $0.1 }
        hidden.forEach { $0.isHidden = false }
        let image = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// Example library that mirrors the design mockups. Only fake data.
@MainActor
enum SnapshotFixtures {
    struct Library {
        let storage: InMemoryPersistence
        let projects: [AudioProject]
        let takes: [UUID: [Take]]
    }

    struct Entry {
        let name: String
        let duration: TimeInterval
        let takeCount: Int
    }

    /// Made-up practice text for the inspector.
    static let sampleScript = """
    Every morning I take the same walk down to the harbor. The boats are still asleep, \
    and the only sound is the water against the stones.

    Some days I bring a notebook. I write down whatever I hear: a gull, a radio from a \
    kitchen window, two fishermen arguing about the weather.

    I started doing this to practice listening. Now I do it because the town sounds \
    different every single day, and I don't want to miss it.
    """

    /// The sample text as timed cues; paragraphs are separated by short pauses.
    static let sampleCues: [SubtitleCue] = {
        let paragraphs = sampleScript.components(separatedBy: "\n\n").map(ScriptSentences.split)
        var cues: [SubtitleCue] = []
        var time: TimeInterval = 160
        for sentences in paragraphs {
            for sentence in sentences {
                let length = Double(sentence.split(separator: " ").count) * 0.45
                cues.append(SubtitleCue(start: time, end: time + length, text: sentence))
                time += length + 0.3
            }
            time += 2
        }
        return cues
    }()

    /// Shows `sampleCues` from an attached .srt, like the practice mockup.
    static func showTimedSubtitles(in practice: PracticeViewModel) {
        practice.subtitles.sources = [SubtitleSourceOption(kind: .subtitleFile, name: "vulnerability.srt")]
        practice.subtitles.activeSource = .subtitleFile
        practice.subtitles.display = .timed(SubtitleTranscript(cues: sampleCues))
    }

    static let names: [Entry] = [
        Entry(name: "TED: The power of vulnerability", duration: 1249, takeCount: 3),
        Entry(name: "BBC 6 Minute English: Why do we procrastinate?", duration: 372, takeCount: 1),
        Entry(name: "Steve Jobs: Stanford commencement speech", duration: 904, takeCount: 0),
        Entry(name: "All Ears English: Small talk", duration: 570, takeCount: 2),
        Entry(name: "Hidden Brain: The easy fix", duration: 761, takeCount: 0)
    ]

    nonisolated static func waveform(duration: TimeInterval, seed: Int) -> WaveformPresentation {
        let pointsPerSecond = 2.0
        let count = max(Int(duration * pointsPerSecond), 8)
        var state = UInt64(seed * 7919 + 17)
        let peaks: [Float] = (0 ..< count).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(state >> 40) / Float(1 << 24)
            let phrase = 0.55 + 0.45 * sin(Float(index) / 9)
            return min(max(0.12 + noise * 0.7 * phrase, 0.05), 1)
        }
        return WaveformPresentation(
            duration: duration,
            sampleRate: 100,
            levels: [WaveformEnvelopeLevel(framesPerPeak: Int(100 / pointsPerSecond), peaks: peaks)],
            warning: nil
        )
    }

    static func library(empty: Bool = false) async throws -> Library {
        let storage = InMemoryPersistence()
        guard !empty else {
            return Library(storage: storage, projects: [], takes: [:])
        }
        let calendar = Calendar(identifier: .gregorian)
        let base = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 21)))
        var projects: [AudioProject] = []
        var takesByProject: [UUID: [Take]] = [:]
        for (index, entry) in names.enumerated() {
            let project = AudioProject(
                id: UUID(),
                sourceDisplayName: entry.name,
                sourceBookmark: Data([1]),
                duration: entry.duration,
                playhead: index == 0 ? 192 : 0,
                currentRegion: nil,
                selectedTakeID: nil,
                keptTakeID: nil,
                lastOpenedAt: base.addingTimeInterval(TimeInterval(-index) * 86400)
            )
            await storage.save(project: project)
            projects.append(project)
            var takes: [Take] = []
            let durations: [TimeInterval] = [108, 185, 252]
            for sequence in stride(from: 1, through: entry.takeCount, by: 1) {
                let start = TimeInterval(sequence - 1) * 30
                let length = durations[(sequence - 1) % durations.count]
                let take = try Take(
                    projectID: project.id,
                    region: PracticeRegion.takeAlignment(
                        start: start,
                        end: min(start + length, entry.duration),
                        sourceDuration: entry.duration
                    ),
                    sequence: sequence,
                    displayOrder: -sequence,
                    relativeAudioPath: "\(project.id.uuidString)/take-\(sequence).caf",
                    duration: length,
                    createdAt: base.addingTimeInterval(TimeInterval(sequence - 3) * 86400 - 3000)
                )
                try await storage.save(take: take)
                takes.append(take)
            }
            takesByProject[project.id] = takes
        }
        return Library(storage: storage, projects: projects, takes: takesByProject)
    }

    static func navigation(
        testCase: XCTestCase,
        library: Library,
        openFirst: Bool
    ) throws -> AppNavigationModel {
        let first = library.projects.first
        let preparer = FixedSessionPreparer(
            prepared: first.map { PreparedPractice(project: $0, waveform: waveform(duration: $0.duration, seed: 1)) }
        )
        let dependencies = try NavigationTestSupport.makeDependencies(
            testCase: testCase,
            storage: library.storage,
            preparer: preparer,
            waveforms: SyntheticWaveforms(),
            // Enables "Generate Subtitles from Audio"; it never runs unless clicked.
            recognizer: FakeSpeechRecognizer()
        )
        let navigation = AppNavigationModel(dependencies: dependencies)
        if openFirst, let first {
            let prepared = PreparedPractice(project: first, waveform: waveform(duration: first.duration, seed: 1))
            navigation.openPrepared(prepared)
        }
        return navigation
    }
}

actor FixedSessionPreparer: PracticeSessionPreparing {
    let prepared: PreparedPractice?

    init(prepared: PreparedPractice?) {
        self.prepared = prepared
    }

    func prepareNewSource(at _: URL) async throws -> PreparedPractice {
        guard let prepared else {
            throw M9TestError.unexpectedPreparation
        }
        return prepared
    }

    func prepareExistingProject(id _: UUID) async throws -> PreparedPractice {
        try await prepareNewSource(at: URL(fileURLWithPath: "/dev/null"))
    }

    func relocateProject(id _: UUID, to url: URL) async throws -> PreparedPractice {
        try await prepareNewSource(at: url)
    }

    func endSession() {}
}

/// Take waveforms for snapshots, derived from the file name so each take looks different.
struct SyntheticWaveforms: WaveformPreparing {
    func prepareWaveform(from url: URL) async throws -> WaveformPresentation {
        let seed = abs(url.lastPathComponent.hashValue % 97) + 3
        return SnapshotFixtures.waveform(duration: 240, seed: seed)
    }
}
