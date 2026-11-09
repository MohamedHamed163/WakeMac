import Foundation
import AVFoundation
import AVFAudio

/// Local Whisper (whisper.cpp) transcription. Audio never leaves the machine:
/// samples are written to a scratch WAV under the app's own directory and fed
/// to the `whisper-cli` binary with a local ggml model, then deleted.

// MARK: - Binary + model discovery

public enum WhisperAssets {
    /// Candidate locations for the whisper.cpp CLI, in priority order.
    static let binaryCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp",
    ]

    /// Directories scanned for `ggml-*.bin` models.
    static func modelDirectories() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        var dirs: [URL] = []
        if let support {
            dirs.append(support.appendingPathComponent("com.local.wakemac/models", isDirectory: true))
            dirs.append(support.appendingPathComponent("MagnaVerse/models", isDirectory: true))
            dirs.append(support.appendingPathComponent("MagnaGalaxy/models", isDirectory: true))
        }
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/share/whisper.cpp/models", isDirectory: true))
        return dirs
    }

    public static func binaryPath() -> String? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every ggml model found on disk, deduplicated by file name.
    public static func availableModels() -> [URL] {
        var seen = Set<String>()
        var found: [URL] = []
        for dir in modelDirectories() {
            let entries = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)) ?? []
            for url in entries where url.lastPathComponent.hasPrefix("ggml-")
                && url.pathExtension == "bin"
                && seen.insert(url.lastPathComponent).inserted {
                found.append(url)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Smallest available model — used for the always-on wake-word window so
    /// ambient listening stays cheap.
    public static func wakeModel() -> URL? {
        let models = availableModels()
        let preference = ["ggml-tiny.en.bin", "ggml-tiny.bin", "ggml-base.en.bin", "ggml-base.bin"]
        for name in preference {
            if let hit = models.first(where: { $0.lastPathComponent == name }) { return hit }
        }
        return models.first
    }

    /// Most capable available model — used for the actual request once awake.
    public static func requestModel() -> URL? {
        let models = availableModels()
        let preference = ["ggml-small.en.bin", "ggml-small.bin", "ggml-medium.en.bin",
                          "ggml-base.en.bin", "ggml-large-v3.bin"]
        for name in preference {
            if let hit = models.first(where: { $0.lastPathComponent == name }) { return hit }
        }
        return models.last
    }
}

// MARK: - 16 kHz mono ring buffer

/// Fixed-capacity ring of 16 kHz mono samples plus a running loudness level.
/// Written from the audio thread, read from the transcription task, so all
/// access goes through one lock.
final class AudioRing: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private let lock = NSLock()
    private(set) var level: Double = 0

    init(seconds: Double = 30) {
        capacity = Int(Self.sampleRate * seconds)
        storage = [Float](repeating: 0, count: capacity)
    }

    /// Root-mean-square of the most recent write, 0…1, for the pulse UI.
    var currentLevel: Double {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    var totalWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        filled += samples.count
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = Double((sum / Float(samples.count)).squareRoot())
        // Smooth so the UI pulse does not jitter, and bias upward so normal
        // speech fills most of the visual range.
        let scaled = min(1.0, rms * 8)
        level = level * 0.6 + scaled * 0.4
        lock.unlock()
    }

    /// The most recent `seconds` of audio, oldest first.
    func tail(seconds: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let want = min(Int(Self.sampleRate * seconds), min(filled, capacity))
        guard want > 0 else { return [] }
        var out = [Float](repeating: 0, count: want)
        var index = (writeIndex - want + capacity) % capacity
        for position in 0..<want {
            out[position] = storage[index]
            index = (index + 1) % capacity
        }
        return out
    }

    /// Mean square energy of the most recent `seconds`, for voice detection.
    func energy(seconds: Double) -> Double {
        let samples = tail(seconds: seconds)
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return Double((sum / Float(samples.count)).squareRoot())
    }

    func reset() {
        lock.lock()
        writeIndex = 0
        filled = 0
        level = 0
        for index in storage.indices { storage[index] = 0 }
        lock.unlock()
    }
}

// MARK: - WAV encoding

enum WAVWriter {
    /// Writes 16 kHz mono signed-16-bit PCM — the only format whisper.cpp reads.
    static func write(samples: [Float], to url: URL) throws {
        let sampleRate = UInt32(AudioRing.sampleRate)
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + byteCount))
        append("WAVE")
        append("fmt ")
        append32(16)                       // PCM chunk size
        append16(1)                        // PCM format
        append16(1)                        // mono
        append32(sampleRate)
        append32(sampleRate * 2)           // byte rate
        append16(2)                        // block align
        append16(16)                       // bits per sample
        append("data")
        append32(UInt32(byteCount))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - whisper-cli invocation

struct WhisperRunner {
    let binary: String
    let scratchDirectory: URL

    /// Transcribes samples with the given model. Returns plain text, or throws
    /// when the binary is missing or exits non-zero.
    func transcribe(samples: [Float], model: URL, threads: Int = 4) throws -> String {
        let wav = scratchDirectory.appendingPathComponent("wake-\(UUID().uuidString).wav")
        try WAVWriter.write(samples: samples, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", model.path,
            "-f", wav.path,
            "-np",            // no banner/log output
            "-nt",            // no timestamps
            "-l", "en",
            "-t", String(threads),
            "--no-fallback",  // keep latency predictable
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WakeError.speechUnavailable("whisper-cli exited \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Streaming transcriber

/// Chunked local transcription built on whisper.cpp.
///
/// In `.wakeWord` mode it keeps re-reading a short trailing window so the wake
/// phrase is noticed quickly and cheaply. In `.utterance` mode it buffers until
/// the speaker stops, then transcribes the whole request once with the larger
/// model, which is both more accurate and cheaper than re-running per chunk.
public final class WhisperTranscriber: Transcribing, @unchecked Sendable {
    public var onTranscript: ((String, Bool) -> Void)?
    public var onLevel: ((Double) -> Void)?
    public private(set) var onDevice = true   // whisper.cpp is always local

    private let ring = AudioRing(seconds: 30)
    private let scratch: URL
    private var runner: WhisperRunner?
    private var wakeModel: URL?
    private var requestModel: URL?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private let stateLock = NSLock()
    private var mode: ListenMode = .wakeWord
    private var loop: Task<Void, Never>?
    private var utteranceStartedAt: Date?
    private var lastVoiceAt: Date?
    private var emittedFinal = false
    private var lastWakeText = ""

    /// Speech is considered present above this RMS. Tuned against built-in mics.
    private let voiceThreshold = 0.012
    /// Silence this long ends an utterance.
    private let silenceToFinish: TimeInterval = 1.1

    public init(scratchDirectory: URL) {
        scratch = scratchDirectory
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    public var level: Double { ring.currentLevel }

    public func prepare() async throws -> String {
        guard let binary = WhisperAssets.binaryPath() else {
            throw WakeError.speechUnavailable(
                "whisper-cli not found — install whisper.cpp (brew install whisper-cpp)")
        }
        guard let request = WhisperAssets.requestModel() else {
            throw WakeError.modelMissing(
                "no ggml-*.bin model found in \(WhisperAssets.modelDirectories().map(\.path).joined(separator: ", "))")
        }
        runner = WhisperRunner(binary: binary, scratchDirectory: scratch)
        requestModel = request
        wakeModel = WhisperAssets.wakeModel() ?? request
        let wakeName = wakeModel?.lastPathComponent ?? "—"
        return "whisper.cpp local — wake: \(wakeName), request: \(request.lastPathComponent)"
    }

    public func begin(mode newMode: ListenMode) throws {
        guard runner != nil else { throw WakeError.speechUnavailable("whisper not prepared") }
        stateLock.lock()
        mode = newMode
        emittedFinal = false
        lastWakeText = ""
        if newMode == .utterance {
            utteranceStartedAt = Date()
            lastVoiceAt = Date()
            ring.reset()
        }
        stateLock.unlock()
        startLoopIfNeeded()
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = resample(buffer) else { return }
        ring.append(samples)
        onLevel?(ring.currentLevel)
        if ring.energy(seconds: 0.25) > voiceThreshold {
            stateLock.lock()
            lastVoiceAt = Date()
            stateLock.unlock()
        }
    }

    public func finish() {
        stateLock.lock()
        let shouldFinalize = mode == .utterance && !emittedFinal
        stateLock.unlock()
        if shouldFinalize { finalizeUtterance() }
    }

    public func reset() {
        loop?.cancel()
        loop = nil
        stateLock.lock()
        utteranceStartedAt = nil
        lastVoiceAt = nil
        emittedFinal = false
        lastWakeText = ""
        stateLock.unlock()
        ring.reset()
    }

    // MARK: - Format conversion

    /// Converts whatever the input node produces into 16 kHz mono floats.
    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioRing.sampleRate,
                                         channels: 1,
                                         interleaved: false) else { return nil }
        if buffer.format.sampleRate == target.sampleRate, buffer.format.channelCount == 1 {
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        if converter == nil || converterInputFormat?.sampleRate != buffer.format.sampleRate
            || converterInputFormat?.channelCount != buffer.format.channelCount {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    // MARK: - Transcription loop

    private func startLoopIfNeeded() {
        guard loop == nil else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        stateLock.lock()
        let currentMode = mode
        let lastVoice = lastVoiceAt
        let alreadyFinal = emittedFinal
        stateLock.unlock()

        switch currentMode {
        case .wakeWord:
            // Only spend CPU when something was actually said.
            guard ring.energy(seconds: 1.0) > voiceThreshold else { return }
            guard let runner, let model = wakeModel else { return }
            let window = ring.tail(seconds: 2.5)
            guard window.count > Int(AudioRing.sampleRate * 0.6) else { return }
            guard let text = try? runner.transcribe(samples: window, model: model, threads: 2) else { return }
            let cleaned = Self.clean(text)
            guard !cleaned.isEmpty else { return }
            stateLock.lock()
            let isNew = cleaned != lastWakeText
            lastWakeText = cleaned
            stateLock.unlock()
            if isNew { onTranscript?(cleaned, false) }

        case .utterance:
            guard !alreadyFinal else { return }
            guard let lastVoice else { return }
            guard Date().timeIntervalSince(lastVoice) >= silenceToFinish else { return }
            finalizeUtterance()
        }
    }

    private func finalizeUtterance() {
        stateLock.lock()
        if emittedFinal { stateLock.unlock(); return }
        emittedFinal = true
        let started = utteranceStartedAt ?? Date()
        stateLock.unlock()

        let spoken = min(28, max(1.0, Date().timeIntervalSince(started)))
        let samples = ring.tail(seconds: spoken)
        guard let runner, let model = requestModel,
              samples.count > Int(AudioRing.sampleRate * 0.4) else {
            onTranscript?("", true)
            return
        }
        let text = (try? runner.transcribe(samples: samples, model: model, threads: 4)) ?? ""
        onTranscript?(Self.clean(text), true)
    }

    /// Strips whisper's non-speech annotations, e.g. "[BLANK_AUDIO]", "(wind)".
    static func clean(_ raw: String) -> String {
        var text = raw
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "\\*[^\\*]*\\*"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
