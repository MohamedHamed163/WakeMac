import Foundation

/// Which speech backend to use. `auto` prefers local whisper.cpp when the
/// binary and a model are present, and falls back to Apple's on-device
/// recognizer; neither sends audio off the machine.
public enum SpeechEngine: String, Codable, Sendable, CaseIterable {
    case auto, whisper, apple
}

/// App settings persisted under Application Support.
public struct WakeSettings: Codable, Sendable {
    public var ollamaBaseURL: String = "http://127.0.0.1:11434"
    public var chatModel: String?
    public var wakePhrase: String = "hi mac"
    public var pushToTalkKeycode: Int = 61       // right option by default
    public var commandTimeoutSeconds: Double = 20
    public var requireOnDeviceRecognition: Bool = true
    public var speakResponses: Bool = true
    public var preventSelfTriggerMillis: Int = 1800
    public var hotkeyShowOverlay: Bool = true
    public var speechEngine: SpeechEngine = .auto
    /// Cover the whole screen while a request is in flight.
    public var immersiveOverlay: Bool = true

    public init() {}

    public static func load(from url: URL) -> WakeSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(WakeSettings.self, from: data) else {
            return WakeSettings()
        }
        return s
    }

    public func save(to url: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

public struct AppPaths: Sendable {
    public let root: URL
    public let settingsPath: URL
    public let dbPath: URL
    public let modesDir: URL

    public init(root: URL) {
        self.root = root
        self.settingsPath = root.appendingPathComponent("settings.json")
        self.dbPath = root.appendingPathComponent("wakemac.sqlite3")
        self.modesDir = root.appendingPathComponent("modes")
    }

    public static func standard(bundleID: String = "com.local.wakemac") -> AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appendingPathComponent(bundleID, isDirectory: true))
    }

    public func ensureDirectories() throws {
        for dir in [root, modesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
