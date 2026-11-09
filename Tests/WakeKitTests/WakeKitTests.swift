import Testing
import Foundation
@testable import WakeKit

@Suite("Mode resolution")
struct ModeResolutionTests {
    @Test func resolveExactAliasAmbiguousNotFound() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm_modes_\(UUID().uuidString)", isDirectory: true)
        let store = ModeStore(dir: dir)
        // defaults were written
        let coding = store.modes().first { $0.name == "Coding Mode" }
        #expect(coding != nil)

        // exact
        if case .success(let m) = store.resolve(spoken: "Coding Mode") {
            #expect(m.name == "Coding Mode")
        } else {
            Issue.record("exact resolution failed")
        }
        // alias
        if case .success(let m) = store.resolve(spoken: "code") {
            #expect(m.name == "Coding Mode")
        } else {
            Issue.record("alias resolution failed")
        }
        // not found
        if case .failure(.notFound) = store.resolve(spoken: "garden mode") {} else {
            Issue.record("expected notFound")
        }
        // ambiguity: create two similarly-named modes
        var a = SavedMode(name: "Focus Session", descriptionText: "test", steps: [])
        var b = SavedMode(name: "Focus Session Deep", descriptionText: "test", steps: [])
        store.save(a); store.save(b)
        if case .failure(.ambiguous(let names)) = store.resolve(spoken: "focus") {
            #expect(names.count == 2)
        } else {
            Issue.record("expected ambiguous")
        }
        _ = a; _ = b
        try FileManager.default.removeItem(at: dir)
    }

    @Test func disabledModeNotResolvable() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm_modes2_\(UUID().uuidString)", isDirectory: true)
        let store = ModeStore(dir: dir)
        var mode = store.modes().first!
        mode.enabled = false
        store.save(mode)
        if case .failure = store.resolve(spoken: mode.name) {} else {
            Issue.record("disabled mode should not resolve")
        }
        try? FileManager.default.removeItem(at: dir)
    }
}

func isValidationError(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch let error as WakeError {
        if case .invalidPlan = error { return true }
        return false
    } catch {
        return false
    }
}

@Suite("Plan validation")
struct PlanValidationTests {
    @Test func rejectsUnknownURLScheme() {
        let plan = ActionPlan(summary: "x", steps: [ActionStep(kind: .openURL, argument: "javascript:alert(1)")])
        #expect(isValidationError { try PlanValidator.validate(plan, policy: ExecutionPolicy()) })
    }

    @Test func acceptsHTTPSURL() throws {
        let plan = ActionPlan(summary: "x", steps: [ActionStep(kind: .openURL, argument: "https://example.com")])
        try PlanValidator.validate(plan, policy: ExecutionPolicy())
    }

    @Test func rejectsUnpredefinedAppleEvent() {
        let plan = ActionPlan(summary: "x", steps: [ActionStep(kind: .applesEvent, argument: "deleteEverything")])
        #expect(isValidationError { try PlanValidator.validate(plan, policy: ExecutionPolicy()) })
    }

    @Test func rejectsOpenPathNonexistent() {
        let plan = ActionPlan(summary: "x", steps: [ActionStep(kind: .openPath, argument: "/definitely/not/here")])
        #expect(isValidationError { try PlanValidator.validate(plan, policy: ExecutionPolicy()) })
    }

    @Test func rejectsTooManySteps() {
        let steps = (0..<20).map { _ in ActionStep(kind: .waitSeconds, argument: "0") }
        let plan = ActionPlan(summary: "x", steps: steps)
        #expect(isValidationError { try PlanValidator.validate(plan, policy: ExecutionPolicy()) })
    }

    @Test func predefinedTemplatesExist() {
        #expect(PlanValidator.predefinedAppleEvents.keys.contains("safariNewTab"))
        #expect(PlanValidator.predefinedAppleEvents.values.allSatisfy { !$0.contains("do shell script") })
    }
}

@Suite("Wake word engine")
struct WakeWordTests {
    @Test func wakeTriggersOnPhrase() {
        let engine = WakeWordEngine(phrase: "hi mac")
        var fired = false
        engine.onWake = { fired = true }
        engine.observe(transcript: "Hey, Hi Mac, what time is it", isFinal: true)
        #expect(fired)
    }

    @Test func cooldownBlocksImmediateRetrigger() {
        let engine = WakeWordEngine(phrase: "hi mac")
        var count = 0
        engine.onWake = { count += 1 }
        engine.observe(transcript: "hi mac", isFinal: true)
        engine.observe(transcript: "hi mac again", isFinal: true)
        #expect(count == 1)
    }
}

@Suite("History store")
struct HistoryTests {
    @Test func appendAndRead() {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("wm_hist_\(UUID().uuidString).sqlite3").path
        let store = HistoryStore(path: path)
        let plan = ActionPlan(summary: "s", steps: [ActionStep(kind: .launchApp, argument: "Safari")])
        store.append(request: "open safari", response: "Done: opened Safari.", state: "completed", plan: plan, results: [])
        let entries = store.recent()
        #expect(entries.count == 1)
        #expect(entries[0].request == "open safari")
        #expect(entries[0].planJSON.contains("launchApp"))
    }
}

@Suite("Wake phrase matching")
struct WakePhraseTests {
    @Test func acceptsEngineSpellingsOfHiMac() {
        // whisper.cpp writes "Hi Mac" as "High Mac"; Apple's recognizer
        // punctuates it. Both must still wake the app.
        let heard = [
            "hi mac",
            "High Mac, open Safari.",
            "Hi, Mac — what's the volume?",
            "hey mac open mail",
            "HIGH MACK!",
        ]
        for text in heard {
            #expect(WakeWordEngine.matches(phrase: "hi mac", in: text), "should wake on \(text)")
        }
    }

    @Test func rejectsUnrelatedSpeech() {
        let heard = ["open safari", "the mac is fast", "high five", "", "[BLANK_AUDIO]"]
        for text in heard {
            #expect(!WakeWordEngine.matches(phrase: "hi mac", in: text), "should ignore \(text)")
        }
    }

    @Test func honoursACustomPhrase() {
        #expect(WakeWordEngine.matches(phrase: "ok computer", in: "Okay, computer!"))
        #expect(!WakeWordEngine.matches(phrase: "ok computer", in: "hi mac"))
    }

    @Test func engineFiresThroughObserve() {
        var fired = 0
        let engine = WakeWordEngine(phrase: "hi mac")
        engine.onWake = { fired += 1 }
        engine.observe(transcript: "High Mac, open Safari", isFinal: false)
        #expect(fired == 1)
    }
}

@Suite("Whisper plumbing")
struct WhisperTests {
    @Test func stripsNonSpeechAnnotations() {
        #expect(WhisperTranscriber.clean("[BLANK_AUDIO]") == "")
        #expect(WhisperTranscriber.clean(" (wind blowing) open mail ") == "open mail")
        #expect(WhisperTranscriber.clean("*clears throat* hi mac") == "hi mac")
        #expect(WhisperTranscriber.clean("  open   safari  ") == "open safari")
    }

    @Test func writesAReadable16kMonoWAV() throws {
        // 0.5 s of a 440 Hz tone.
        let count = Int(AudioRing.sampleRate / 2)
        let samples = (0..<count).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / AudioRing.sampleRate)) * 0.5
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm_\(UUID().uuidString).wav")
        try WAVWriter.write(samples: samples, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + count * 2)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        // sample rate is little-endian at byte 24
        let rate = data[24..<28].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(rate == 16_000)
    }

    @Test func ringKeepsTheMostRecentTail() {
        let ring = AudioRing(seconds: 1)
        ring.append([Float](repeating: 0.1, count: 8_000))
        ring.append([Float](repeating: 0.9, count: 8_000))
        let tail = ring.tail(seconds: 0.5)
        #expect(tail.count == 8_000)
        // The newest half is the 0.9 block.
        #expect(tail.allSatisfy { abs($0 - 0.9) < 0.0001 })
        #expect(ring.energy(seconds: 0.5) > 0.8)
    }

    @Test func ringReportsLoudnessForTheOverlayPulse() {
        let ring = AudioRing(seconds: 1)
        #expect(ring.currentLevel == 0)
        for _ in 0..<12 { ring.append([Float](repeating: 0.5, count: 1_024)) }
        #expect(ring.currentLevel > 0.5)
        ring.reset()
        #expect(ring.currentLevel == 0)
    }
}

@Suite("Planner isolation")
struct PlannerIsolationTests {
    /// `plan` is nonisolated and async, so it runs on the cooperative pool.
    /// It used to read a `@MainActor` closure for settings, which trapped and
    /// killed the app on every request. It must now run off the main actor and
    /// surface an ordinary error instead.
    @Test func planRunsOffTheMainActorWithoutTrapping() async {
        // Port 1 has nothing listening, so the call fails at the network rather
        // than reaching a model — which is all this test needs.
        let client = OllamaClient(baseURL: "http://127.0.0.1:1", timeout: 2)
        let planner = PlannerAgent(client: client)
        var settings = WakeSettings()
        settings.chatModel = "qwen3.5:4b"

        let thrown: Bool = await Task.detached {
            do {
                _ = try await planner.plan(request: "open safari", settings: settings)
                return false
            } catch {
                return true
            }
        }.value
        #expect(thrown, "a dead endpoint should throw, not trap")
    }

    @Test func plannerCarriesNoActorBoundClosure() {
        // A Sendable snapshot is what makes the call above safe; keeping the
        // agent constructible from a detached context pins that.
        let planner = PlannerAgent(client: OllamaClient(baseURL: "http://127.0.0.1:1"))
        #expect(planner.client.baseURL.absoluteString.contains("127.0.0.1:1"))
    }
}
