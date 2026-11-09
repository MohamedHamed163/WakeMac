import Foundation
import AppKit
import SwiftUI
import os

/// Session state machine: standby → listening → transcribing → thinking →
/// executing → speaking → (cancelled | failed) → standby.
@MainActor
public final class AppState: ObservableObject {
    public enum Phase: String, Sendable {
        case standby, listening, transcribing, thinking, executing, speaking
        case cancelled, failed
    }

    @Published public private(set) var phase: Phase = .standby {
        didSet {
            let isListening = phase == .listening
            listeningFlag.withLock { $0 = isListening }
        }
    }
    /// Thread-safe mirror of `phase == .listening` for the audio thread, which must not touch the main actor.
    private let listeningFlag = OSAllocatedUnfairLock(initialState: false)
    @Published public var transcript = ""
    @Published public var request = ""
    @Published public var answer = ""
    @Published public var statusDetail = ""
    @Published public var planSummary = ""
    @Published public var results: [ActionResult] = []
    @Published public var speechStatus = ""        // honest capability report
    @Published public var micPermissionDenied = false
    @Published public var typedInput = ""
    @Published public var showingOverlay = false
    /// Live microphone loudness, 0…1, driving the overlay's pulse rings.
    @Published public var audioLevel: Double = 0
    /// Which speech backend actually prepared, for the overlay's footer.
    @Published public var engineLabel = ""

    public var settings: WakeSettings
    public let paths: AppPaths
    public let capture: AudioCapture
    public let transcriber: Transcribing
    public let wakeEngine: WakeWordEngine
    public let speechOutput: SpeechOutput
    public let modeStore: ModeStore
    public let history: HistoryStore
    public let executor: ActionExecutor
    private let ollama: OllamaClient
    private var planner: PlannerAgent?
    private var sessionTask: Task<Void, Never>?
    private var lastSpeakTime: Date?

    public init() {
        let paths = AppPaths.standard()
        try? paths.ensureDirectories()
        let settings = WakeSettings.load(from: paths.settingsPath)
        self.paths = paths
        self.settings = settings
        self.capture = AudioCapture()
        // Prefer local whisper.cpp when it is installed; fall back to Apple's
        // on-device recognizer otherwise. Both keep audio on this machine.
        if settings.speechEngine == .apple || WhisperAssets.binaryPath() == nil {
            self.transcriber = SpeechTranscriber()
        } else {
            self.transcriber = WhisperTranscriber(
                scratchDirectory: paths.root.appendingPathComponent("scratch", isDirectory: true))
        }
        self.wakeEngine = WakeWordEngine(phrase: settings.wakePhrase)
        self.speechOutput = SpeechOutput()
        self.modeStore = ModeStore(dir: paths.modesDir)
        self.history = HistoryStore(path: paths.dbPath.path)
        self.executor = ActionExecutor()
        self.speechOutput.enabled = settings.speakResponses
        self.ollama = OllamaClient(baseURL: settings.ollamaBaseURL,
                                   timeout: settings.commandTimeoutSeconds)
        planner = PlannerAgent(client: ollama)
        wirePipeline()
    }

    private func wirePipeline() {
        wakeEngine.onWake = { [weak self] in
            Task { @MainActor in self?.beginInteraction(fromVoice: true) }
        }
        transcriber.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == .standby {
                    // Ambient pass: the only thing we look for is the wake phrase.
                    self.wakeEngine.observe(transcript: text, isFinal: isFinal)
                    return
                }
                self.transcript = text
                if isFinal && self.phase == .listening {
                    self.completeListening(transcript: text)
                }
            }
        }
        transcriber.onLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        speechOutput.onSpeakEnd = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // self-trigger prevention: cooldown matching TTS length
                let spoken = Date().timeIntervalSince(self.lastSpeakTime ?? Date())
                self.wakeEngine.cooldown(seconds: max(Double(self.settings.preventSelfTriggerMillis) / 1000.0, min(spoken * 0.3, 4)))
                self.phase = .standby
                if !self.settings.hotkeyShowOverlay { self.showingOverlay = false }
                // Re-arm ambient wake detection for the next "hi mac".
                self.transcriber.reset()
                try? self.transcriber.begin(mode: .wakeWord)
            }
        }
        capture.onBuffer = { [weak self] buffer in
            guard let self else { return }
            if self.listeningFlag.withLock({ $0 }) {
                self.transcriber.append(buffer)
            }
        }
    }

    /// Prepares speech stack honestly; typed fallback remains if unavailable.
    public func bootstrap() async {
        do {
            speechStatus = try await transcriber.prepare()
            engineLabel = transcriber is WhisperTranscriber ? "whisper.cpp (local)" : "Apple on-device"
            if transcriber.onDevice {
                try await startAmbientListening()
            } else {
                statusDetail = speechStatus
            }
        } catch {
            speechStatus = String(describing: error)
            statusDetail = speechStatus
        }
        _ = await checkOllama()
    }

    public func checkOllama() async -> Bool {
        do {
            let models = try await ollama.listModels()
            statusDetail = "\(models.count) local models; \(statusDetail)"
            return true
        } catch {
            statusDetail = "Ollama unreachable — typed input still works, reasoning disabled."
            return false
        }
    }

    func startAmbientListening() async throws {
        let granted = await capture.checkPermission()
        guard granted else {
            micPermissionDenied = true
            speechStatus = "Microphone permission denied — use typed input or the hotkey."
            return
        }
        try capture.start()
        // A session that is already live keeps dictating; only an idle app
        // falls back to listening for the wake phrase.
        if phase == .standby {
            try transcriber.begin(mode: .wakeWord)
        }
    }

    /// "Hi Mac" (or hotkey) → open overlay + active listening session.
    public func beginInteraction(fromVoice: Bool) {
        showingOverlay = true
        phase = .listening
        transcript = ""
        request = ""
        answer = ""
        results = []
        planSummary = ""
        statusDetail = "listening… (say your request, or type below)"
        if !capture.micOn {
            Task { [weak self] in
                try? await self?.startAmbientListening()
                try? self?.transcriber.begin(mode: .utterance)
            }
        } else {
            transcriber.reset()
            try? transcriber.begin(mode: .utterance)
        }
    }

    func completeListening(transcript: String) {
        guard !transcript.isEmpty else {
            phase = .standby
            return
        }
        request = transcript
        runRequest(transcript)
    }

    /// Typed-input path (keyboard fallback / no speech assets).
    public func submitTyped() {
        let text = typedInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        typedInput = ""
        request = text
        runRequest(text)
    }

    public func stopOrCancel() {
        sessionTask?.cancel()
        transcriber.reset()
        phase = .cancelled
        history.append(request: request, response: answer, state: "cancelled",
                       plan: nil, results: results)
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if phase == .cancelled { phase = .standby }
        }
    }

    func runRequest(_ text: String) {
        phase = .thinking
        statusDetail = "planning…"
        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let planner = self.planner else {
                    throw WakeError.modelMissing("planner")
                }
                // Read settings here, on the main actor, because `plan` runs off it.
                let snapshot = self.settings
                let plan = try await planner.plan(request: text, settings: snapshot)
                self.planSummary = plan.summary
                self.phase = .executing
                self.statusDetail = plan.summary
                let results = try await self.executor.execute(plan)
                self.results = results
                let ok = !results.isEmpty && results.allSatisfy(\.success)
                self.answer = self.summarize(results: results, success: ok)
                self.phase = .speaking
                self.lastSpeakTime = Date()
                self.history.append(request: text, response: self.answer,
                                    state: ok ? "completed" : "failed",
                                    plan: plan, results: results)
                self.speechOutput.speak(self.answer)
            } catch is CancellationError {
                self.phase = .cancelled
            } catch {
                self.phase = .failed
                self.statusDetail = String(describing: error)
                self.answer = "I could not complete that: \(error)"
                self.lastSpeakTime = Date()
                self.history.append(request: text, response: self.answer,
                                    state: "failed", plan: nil, results: [])
                self.speechOutput.speak(self.answer)
            }
        }
    }

    func summarize(results: [ActionResult], success: Bool) -> String {
        if results.isEmpty { return "Nothing to do." }
        let good = results.filter(\.success).count
        let names = results.map { result in
            switch result.step.kind {
            case .launchApp: return "opened \(result.step.argument)"
            case .openURL: return "opened link"
            case .openPath: return "opened item"
            case .runShortcut: return "ran shortcut \(result.step.argument)"
            case .applesEvent: return "did \(result.step.argument)"
            case .typeText: return "typed text"
            case .keystroke: return "pressed \(result.step.argument)"
            case .waitSeconds: return "waited"
            case .setVolume: return "set volume"
            }
        }.joined(separator: ", ")
        return success ? "Done: \(names)." : "Completed \(good) of \(results.count) steps: \(names)."
    }

    /// Resolves and runs a saved mode by spoken/typed name.
    public func runMode(named name: String) {
        switch modeStore.resolve(spoken: name) {
        case .success(let mode):
            runRequest("run steps of mode \(mode.name): " + mode.steps.map { "\($0.kind.rawValue):\($0.argument)" }.joined(separator: "; "))
        case .failure(let error):
            phase = .failed
            statusDetail = String(describing: error)
            answer = String(describing: error)
        }
    }
}
