import Foundation
import AppKit

/// Typed desktop action system. Ordinary Swift code validates and executes;
/// model text is never interpolated into shell commands.

public enum ActionKind: String, Codable, Sendable, CaseIterable {
    case launchApp            // resolve + activate via NSWorkspace
    case openURL              // validated URL
    case openPath             // user-selected or whitelisted file/folder
    case runShortcut          // existing Shortcuts shortcut by name
    case applesEvent          // predefined AppleEvent scripts (fixed templates)
    case typeText             // paste-into-frontmost (accessibility)
    case keystroke            // single named key (escape, return...)
    case waitSeconds
    case setVolume
}

public struct ActionStep: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ActionKind
    public var argument: String           // validated argument (app name, URL, shortcut name…)
    public var extra: String?             // optional secondary argument (text for typeText)
    public var timeoutSeconds: Double
    public var verify: Bool
    public var reversible: Bool

    public init(id: String = UUID().uuidString, kind: ActionKind, argument: String,
                extra: String? = nil, timeoutSeconds: Double = 10,
                verify: Bool = true, reversible: Bool = false) {
        self.id = id
        self.kind = kind
        self.argument = argument
        self.extra = extra
        self.timeoutSeconds = timeoutSeconds
        self.verify = verify
        self.reversible = reversible
    }
}

public struct ActionPlan: Codable, Sendable {
    public var summary: String
    public var steps: [ActionStep]

    public init(summary: String, steps: [ActionStep]) {
        self.summary = summary
        self.steps = steps
    }
}

public struct ActionResult: Codable, Sendable, Identifiable {
    public var id: String
    public var step: ActionStep
    public var success: Bool
    public var verification: String
    public var startedAt: Date
    public var finishedAt: Date
    public var error: String?
}

public struct ExecutionPolicy: Codable, Sendable {
    public var confirmDestructive: Bool = true
    public var stopOnFirstFailure: Bool = true
    public var maxSteps: Int = 12
    public var allowShell: Bool = false        // never interpolate model text
    public var maxWaitSeconds: Double = 30
    public init() {}
}

/// Plan validation: argument checks per action kind.
public enum PlanValidator {
    public static func validate(_ plan: ActionPlan, policy: ExecutionPolicy) throws {
        if plan.steps.count > policy.maxSteps {
            throw WakeError.invalidPlan("too many steps (\(plan.steps.count) > \(policy.maxSteps))")
        }
        for step in plan.steps {
            switch step.kind {
            case .openURL:
                guard let url = URL(string: step.argument),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto", "file"].contains(scheme) else {
                    throw WakeError.invalidPlan("openURL argument is not a valid URL: \(step.argument.prefix(120))")
                }
            case .openPath:
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: step.argument, isDirectory: &isDir) else {
                    throw WakeError.invalidPlan("openPath does not exist: \(step.argument)")
                }
            case .launchApp:
                guard !step.argument.contains("/") && step.argument.count < 80 else {
                    throw WakeError.invalidPlan("launchApp expects an app name: \(step.argument)")
                }
            case .runShortcut:
                guard !step.argument.isEmpty && step.argument.count < 100 else {
                    throw WakeError.invalidPlan("runShortcut needs a shortcut name")
                }
            case .applesEvent:
                guard Self.predefinedAppleEvents.keys.contains(step.argument) else {
                    throw WakeError.invalidPlan("applesEvent '\(step.argument)' is not a predefined template")
                }
            case .typeText:
                if let text = step.extra, text.count > 2000 {
                    throw WakeError.invalidPlan("typeText too long")
                }
            case .keystroke, .waitSeconds, .setVolume:
                break
            }
        }
    }

    /// Fixed Apple Events templates — no model-authored scripts, ever.
    public static let predefinedAppleEvents: [String: String] = [
        "safariNewTab": """
        tell application "Safari" to activate
        tell application "System Events" to keystroke "t" using command down
        """,
        "finderNewFolder": """
        tell application "Finder" to activate
        tell application "System Events" to keystroke "n" using {command down, shift down}
        """,
        "saveFrontmost": """
        tell application "System Events" to keystroke "s" using command down
        """,
        "spotlightSearch": """
        tell application "System Events" to keystroke space using command down
        """,
        "missionControl": """
        tell application "System Events" to key code 126 using {control down}
        """,
    ]
}

/// Executes validated plans with verification, timestamps and cancellation.
@MainActor
public final class ActionExecutor: ObservableObject {
    @Published public private(set) var results: [ActionResult] = []
    @Published public private(set) var running = false

    public private(set) var lastRunCancelled = false
    private var cancelRequested = false

    public init() {}

    public func cancel() {
        cancelRequested = true
        lastRunCancelled = true
    }

    public func execute(_ plan: ActionPlan, policy: ExecutionPolicy = ExecutionPolicy()) async throws -> [ActionResult] {
        try PlanValidator.validate(plan, policy: policy)
        cancelRequested = false
        lastRunCancelled = false
        running = true
        results = []
        defer { running = false }

        for step in plan.steps {
            if cancelRequested { break }
            let started = Date()
            let result = await runStep(step)
            let finished = Date()
            let actionResult = ActionResult(id: step.id, step: step, success: result.success,
                                            verification: result.verification,
                                            startedAt: started, finishedAt: finished,
                                            error: result.error)
            results.append(actionResult)
            if !actionResult.success && policy.stopOnFirstFailure {
                break
            }
        }
        return results
    }

    struct StepOutcome {
        var success: Bool
        var verification: String
        var error: String?
    }

    private func runStep(_ step: ActionStep) async -> StepOutcome {
        switch step.kind {
        case .launchApp:
            return await launchApp(named: step.argument)
        case .openURL:
            guard let url = URL(string: step.argument) else {
                return StepOutcome(success: false, verification: "", error: "bad url")
            }
            NSWorkspace.shared.open(url)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return StepOutcome(success: true, verification: "opened \(url.host ?? url.path)")
        case .openPath:
            let url = URL(fileURLWithPath: step.argument)
            let ok = NSWorkspace.shared.open(url)
            return StepOutcome(success: ok, verification: ok ? "opened path" : "workspace refused", error: ok ? nil : "open failed")
        case .runShortcut:
            return await runShortcut(named: step.argument)
        case .applesEvent:
            return await runAppleEvent(template: step.argument)
        case .typeText:
            return await typeText(step.extra ?? step.argument)
        case .keystroke:
            return await keystroke(named: step.argument)
        case .waitSeconds:
            let secs = min(Double(step.argument) ?? 1.0, 10)
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            return StepOutcome(success: true, verification: "waited \(secs)s")
        case .setVolume:
            let level = max(0, min(100, Double(step.argument) ?? 50))
            let script = "set volume output volume \(Int(level))"
            return await runOSA(script, verifyContains: nil)
        }
    }

    private func launchApp(named name: String) async -> StepOutcome {
        let workspace = NSWorkspace.shared
        var outcome = StepOutcome(success: false, verification: "", error: nil)
        if let url = workspace.urlForApplication(withBundleIdentifier: name) {
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            outcome.success = true
            outcome.verification = "activated bundle \(name)"
            return outcome
        }
        let apps = URL(fileURLWithPath: "/System/Applications")
        let legacy = URL(fileURLWithPath: "/Applications")
        for dir in [legacy, apps] {
            let candidate = dir.appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                workspace.openApplication(at: candidate, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                outcome.success = true
                outcome.verification = "launched \(candidate.lastPathComponent)"
                return outcome
            }
        }
        if let appURL = installedAppURL(matching: name) {
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            outcome.success = true
            outcome.verification = "launched \(name)"
            return outcome
        }
        outcome.error = "app not found: \(name)"
        return outcome
    }

    /// Scans application directories for a case-insensitive name match.
    private func installedAppURL(matching name: String) -> URL? {
        let dirs = ["/Applications", "/System/Applications",
                    "/System/Applications/Utilities", "/Applications/Utilities"]
        for dir in dirs {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if let hit = contents.first(where: {
                $0.hasSuffix(".app") && $0.dropLast(4).caseInsensitiveCompare(name) == .orderedSame
            }) {
                return URL(fileURLWithPath: dir).appendingPathComponent(hit)
            }
        }
        return nil
    }

    private func runShortcut(named name: String) async -> StepOutcome {
        // Argument-array invocation; no shell interpolation.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return StepOutcome(success: false, verification: "", error: "shortcuts tool missing: \(error)")
        }
        let waitTask = Task {
            while p.isRunning {
                if self.cancelRequested { p.terminate(); break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        p.waitUntilExit()
        waitTask.cancel()
        let status = p.terminationStatus
        return StepOutcome(success: status == 0,
                           verification: "shortcuts exit=\(status)",
                           error: status == 0 ? nil : "shortcut failed (name may not exist)")
    }

    private func runAppleEvent(template: String) async -> StepOutcome {
        guard let script = PlanValidator.predefinedAppleEvents[template] else {
            return StepOutcome(success: false, verification: "", error: "unknown template")
        }
        return await runOSA(script, verifyContains: nil)
    }

    private func typeText(_ text: String) async -> StepOutcome {
        // Clipboard-paste path: reliable, no per-keystroke injection.
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let script = """
        tell application "System Events" to keystroke "v" using command down
        """
        let outcome = await runOSA(script, verifyContains: nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
        return outcome
    }

    private func keystroke(named name: String) async -> StepOutcome {
        let keyMap = ["escape": "key code 53", "return": "key code 36",
                      "space": "key code 49", "tab": "key code 48"]
        guard let action = keyMap[name.lowercased()] else {
            return StepOutcome(success: false, verification: "", error: "unknown key: \(name)")
        }
        let script = "tell application \"System Events\" to \(action)"
        return await runOSA(script, verifyContains: nil)
    }

    private func runOSA(_ script: String, verifyContains: String?) async -> StepOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]     // script is a fixed template, never model text
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return StepOutcome(success: false, verification: "", error: "osascript failed: \(error)")
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let ok = p.terminationStatus == 0
        var verification = "exit=\(p.terminationStatus)"
        if let expect = verifyContains {
            verification += output.contains(expect) ? " (verified: contains '\(expect)')" : " (verification failed)"
            return StepOutcome(success: ok && output.contains(expect), verification: verification,
                               error: ok && output.contains(expect) ? nil : "verification failed")
        }
        return StepOutcome(success: ok, verification: verification,
                           error: ok ? nil : output)
    }
}
