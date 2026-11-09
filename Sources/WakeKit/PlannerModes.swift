import Foundation

/// Planner Agent: converts a request into a validated typed ActionPlan.
/// Structured output is validated by PlanValidator before execution; the
/// model never executes anything directly.
public struct PlannerAgent: Sendable {
    public let client: OllamaClient

    public init(client: OllamaClient) {
        self.client = client
    }

    public struct PlanEnvelope: Decodable, Sendable {
        public let summary: String
        public let steps: [StepEnvelope]
    }
    public struct StepEnvelope: Decodable, Sendable {
        public let kind: String
        public let argument: String
        public let extra: String?
        public let verify: Bool?
    }

    public static let supportedKinds = Set(ActionKind.allCases.map(\.rawValue))

    /// Converts one request into a validated plan.
    /// - Parameters:
    ///   - request: the user's spoken or typed request.
    ///   - settings: a snapshot taken by the caller on the main actor.
    /// - Returns: the validated plan.
    public func plan(request: String, settings: WakeSettings) async throws -> ActionPlan {
        let models = try await client.listModels()
        guard let model = settings.chatModel ?? models.first(where: { $0.supports("tools") })?.name
                            ?? models.first?.name else {
            throw WakeError.modelMissing("tools")
        }
        let system = """
        You convert a desktop request into a typed action plan for macOS.
        Allowed step kinds ONLY: launchApp, openURL, openPath, runShortcut, applesEvent, typeText, keystroke, waitSeconds, setVolume.
        - launchApp argument = app name (no path).
        - openURL argument = full https/http URL.
        - applesEvent argument = one of exactly: \(PlanValidator.predefinedAppleEvents.keys.sorted().joined(separator: ", ")).
        - keystroke argument = one of: escape, return, space, tab.
        - Do not invent other kinds. Keep plans minimal (usually 1-4 steps).
        Reply ONLY JSON: {"summary":"...","steps":[{"kind":"...","argument":"...","extra":null,"verify":true}]}
        """
        let content = try await client.chatStream(model: model, messages: [
            ("system", system),
            ("user", "Request: \(request)")
        ])
        guard let data = content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PlanEnvelope.self, from: data) else {
            throw WakeError.invalidPlan("model output was not a valid plan")
        }
        let steps = envelope.steps.compactMap { step -> ActionStep? in
            guard let kind = ActionKind(rawValue: step.kind),
                  Self.supportedKinds.contains(step.kind) else { return nil }
            return ActionStep(kind: kind, argument: step.argument, extra: step.extra,
                              verify: step.verify ?? true)
        }
        guard !steps.isEmpty else {
            throw WakeError.invalidPlan("plan has no valid steps")
        }
        return ActionPlan(summary: envelope.summary, steps: steps)
    }
}

/// Saved modes: named ordered step lists with policy + run history.
public struct SavedMode: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var descriptionText: String
    public var steps: [ActionStep]
    public var version: Int
    public var enabled: Bool
    public var preconditions: String?

    public init(id: String = UUID().uuidString, name: String, aliases: [String] = [],
                descriptionText: String, steps: [ActionStep], version: Int = 1,
                enabled: Bool = true, preconditions: String? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.descriptionText = descriptionText
        self.steps = steps
        self.version = version
        self.enabled = enabled
        self.preconditions = preconditions
    }
}

public final class ModeStore: Sendable {
    private let dir: URL
    private let lock = NSLock()

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if Self.loadModes(from: dir).isEmpty {
            Self.writeDefaults(to: dir)
        }
    }

    public func modes() -> [SavedMode] {
        Self.loadModes(from: dir)
    }

    public func save(_ mode: SavedMode) {
        lock.lock(); defer { lock.unlock() }
        let url = dir.appendingPathComponent("\(mode.id).json")
        if let data = try? JSONEncoder().encode(mode) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func delete(_ mode: SavedMode) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(mode.id).json"))
    }

    public func duplicate(_ mode: SavedMode) -> SavedMode {
        var copy = mode
        copy.id = UUID().uuidString
        copy.name = mode.name + " Copy"
        copy.version = 1
        save(copy)
        return copy
    }

    /// Resolves "run mode one" — exact name, alias, or case-insensitive
    /// contains; ambiguity is reported, never silently resolved.
    public func resolve(spoken: String) -> Result<SavedMode, ModeResolutionError> {
        let all = modes().filter(\.enabled)
        let query = spoken.trimmingCharacters(in: .whitespaces)
        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return .success(exact)
        }
        let aliasMatches = all.filter { mode in
            mode.aliases.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }
        if aliasMatches.count == 1 { return .success(aliasMatches[0]) }
        let contains = all.filter { $0.name.lowercased().contains(query.lowercased()) }
        if contains.count == 1 { return .success(contains[0]) }
        if contains.count > 1 || aliasMatches.count > 1 {
            return .failure(.ambiguous(contains.map(\.name) + aliasMatches.map(\.name)))
        }
        return .failure(.notFound(query))
    }

    public enum ModeResolutionError: Error, CustomStringConvertible {
        case notFound(String)
        case ambiguous([String])
        public var description: String {
            switch self {
            case .notFound(let q): return "No mode named '\(q)'"
            case .ambiguous(let names): return "Ambiguous mode name; matches: \(names.joined(separator: ", "))"
            }
        }
    }

    static func loadModes(from dir: URL) -> [SavedMode] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SavedMode.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    static func writeDefaults(to dir: URL) {
        let examples = [
            SavedMode(name: "Coding Mode", aliases: ["code", "coding"],
                      descriptionText: "Open the selected editor, repository and documentation.",
                      steps: [
                        ActionStep(kind: .launchApp, argument: "Terminal"),
                        ActionStep(kind: .applesEvent, argument: "spotlightSearch", verify: true),
                      ],
                      preconditions: "Requires Accessibility permission for keystrokes."),
            SavedMode(name: "Research Mode", aliases: ["research"],
                      descriptionText: "Open selected sources and a notes window.",
                      steps: [
                        ActionStep(kind: .openURL, argument: "https://arxiv.org"),
                        ActionStep(kind: .launchApp, argument: "Notes"),
                      ]),
            SavedMode(name: "Presentation Mode", aliases: ["present", "presentation"],
                      descriptionText: "Open the chosen slide deck and related notes.",
                      steps: [
                        ActionStep(kind: .launchApp, argument: "Keynote"),
                        ActionStep(kind: .launchApp, argument: "Notes"),
                      ],
                      preconditions: "Edit the openPath step to your deck."),
        ]
        for mode in examples {
            let url = dir.appendingPathComponent("\(mode.id).json")
            if let data = try? JSONEncoder().encode(mode) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
