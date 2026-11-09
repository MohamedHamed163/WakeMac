import Foundation
import AVFoundation
import AVFAudio
import Speech

/// How the transcriber should listen right now.
public enum ListenMode: Sendable {
    /// Always-on, cheap, looking only for the wake phrase.
    case wakeWord
    /// A real request is being dictated; accuracy matters.
    case utterance
}

/// Common surface for the speech backends (Apple on-device, whisper.cpp) so
/// the session state machine does not care which one is installed.
public protocol Transcribing: AnyObject, Sendable {
    var onTranscript: ((String, Bool) -> Void)? { get set }
    var onLevel: ((Double) -> Void)? { get set }
    var onDevice: Bool { get }
    func prepare() async throws -> String
    func begin(mode: ListenMode) throws
    func append(_ buffer: AVAudioPCMBuffer)
    func finish()
    func reset()
}

/// Microphone capture via AVAudioEngine. Raw audio is not retained — only
/// recognition buffers flow to the transcriber and are discarded.
public final class AudioCapture: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    public private(set) var micOn = false
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onDeviceChange: (() -> Void)?
    /// Format of the live input node, once capture has started.
    public private(set) var inputFormat: AVAudioFormat?

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange),
                                               name: NSNotification.Name("AVAudioEngineConfigurationChange"),
                                               object: engine)
    }

    deinit {
        engine.stop()
    }

    public func checkPermission() async -> Bool {
        await withCheckedContinuation { cont in
            switch AVAudioApplication.shared.recordPermission {
            case .granted: cont.resume(returning: true)
            case .denied: cont.resume(returning: false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            @unknown default: cont.resume(returning: false)
            }
        }
    }

    public func start() throws {
        guard !micOn else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        self.inputFormat = format
        engine.prepare()
        try engine.start()
        micOn = true
    }

    public func stop() {
        guard micOn else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micOn = false
    }

    @objc private func handleRouteChange() {
        onDeviceChange?()
        if micOn {
            // restart on route change (headphones plugged/unplugged)
            stop()
            try? start()
        }
    }
}

/// On-device speech transcription. Requires on-device recognition when
/// configured; never falls back to server-based (cloud) recognition.
public final class SpeechTranscriber: Transcribing, @unchecked Sendable {
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    public private(set) var onDevice = false
    public var onTranscript: ((String, Bool) -> Void)?
    public var onLevel: ((Double) -> Void)?

    public init(localeID: String = "en-US") {
        locale = Locale(identifier: localeID)
    }

    /// Prepares the recognizer and reports honest availability state.
    public func prepare() async throws -> String {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw WakeError.permissionDenied("speech recognition authorization: \(status.rawValue)")
        }
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw WakeError.speechUnavailable("no recognizer for \(locale.identifier)")
        }
        recognizer = rec
        onDevice = rec.supportsOnDeviceRecognition
        if !onDevice {
            // Honest: on-device unsupported here. We do NOT use cloud.
            return "on-device recognition NOT supported for \(locale.identifier) on this device — dictation-based wake disabled; typed input and push-to-talk still work."
        }
        return "on-device recognition available"
    }

    public func begin(mode: ListenMode = .utterance) throws {
        guard recognizer != nil else {
            throw WakeError.speechUnavailable("recognizer not prepared")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if onDevice {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        guard let recognizer else { throw WakeError.speechUnavailable("recognizer missing") }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                let final = result.isFinal
                self?.onTranscript?(text, final)
            }
            if error != nil {
                self?.onTranscript?("", true)
            }
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    public func finish() {
        request?.endAudio()
    }

    public func reset() {
        task?.cancel()
        task = nil
        request = nil
    }
}

/// Wake word engine: transcription-based "Hi Mac" detection with
/// self-trigger prevention. Interface allows a future dedicated local
/// keyword detector to replace it.
public final class WakeWordEngine: @unchecked Sendable {
    public let phrase: String
    public var cooldownUntil: Date = .distantPast
    public var onWake: (() -> Void)?
    private var armed = true

    public init(phrase: String = "hi mac") {
        self.phrase = phrase.lowercased()
    }

    /// Suppresses detection right after the assistant speaks (TTS self-trigger
    /// prevention) or while a session is active.
    public func cooldown(seconds: Double) {
        cooldownUntil = Date().addingTimeInterval(seconds)
        armed = false
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.armed = true
        }
    }

    public func observe(transcript: String, isFinal: Bool) {
        guard armed, Date() >= cooldownUntil else { return }
        if Self.matches(phrase: phrase, in: transcript) {
            armed = false
            onWake?()
        }
    }

    /// True when `text` contains the wake phrase, allowing for the spellings
    /// speech engines actually produce ("High Mac", "Hey Mac", "Hi Mack") and
    /// for punctuation around it.
    public static func matches(phrase: String, in text: String) -> Bool {
        let normalized = normalize(text)
        for variant in variants(of: phrase) where normalized.contains(variant) {
            return true
        }
        return false
    }

    /// Lowercases, drops punctuation and collapses runs of whitespace.
    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character.isWhitespace ? character : " "
        }
        return String(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Homophones of the first word, so "hi mac" also fires on "high mac".
    static func variants(of phrase: String) -> [String] {
        let normalized = normalize(phrase)
        var words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first else { return [normalized] }
        let homophones: [String: [String]] = [
            "hi": ["hi", "high", "hey", "hai"],
            "hey": ["hey", "hay", "hi", "a"],
            "ok": ["ok", "okay"],
        ]
        let alternatives = homophones[first] ?? [first]
        let tailWords = words.dropFirst().joined(separator: " ")
        var out = alternatives.map { tailWords.isEmpty ? $0 : "\($0) \(tailWords)" }
        // "mac" is also heard as "mack" / "mc".
        if tailWords == "mac" {
            out += alternatives.flatMap { ["\($0) mack", "\($0) mc"] }
        }
        words = []
        return out
    }
}

/// Speech output via AVSpeechSynthesizer, with self-trigger cooldown hook.
public final class SpeechOutput: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    public var onSpeakStart: (() -> Void)?
    public var onSpeakEnd: (() -> Void)?
    public var enabled: Bool = true

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) {
        guard enabled, !text.isEmpty else {
            onSpeakEnd?()
            return
        }
        let utterance = AVSpeechUtterance(string: String(text.prefix(400)))
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSpeakStart?()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeakEnd?()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onSpeakEnd?()
    }
}
