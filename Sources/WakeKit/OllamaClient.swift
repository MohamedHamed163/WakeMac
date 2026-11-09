import Foundation

/// Typed Ollama client for Wake Mac reasoning. Local endpoint only.
public final class OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: String, timeout: TimeInterval = 60) {
        var cleaned = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if cleaned.isEmpty { cleaned = "http://127.0.0.1:11434" }
        self.baseURL = URL(string: cleaned)!
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: cfg)
    }

    public struct ModelInfo: Sendable, Codable {
        public let name: String
        public let capabilities: [String]
        public func supports(_ c: String) -> Bool { capabilities.contains(c) }
    }

    public func listModels() async throws -> [ModelInfo] {
        struct Resp: Decodable {
            struct Entry: Decodable { let name: String; let capabilities: [String]? }
            let models: [Entry]
        }
        let (data, resp) = try await session.data(from: baseURL.appendingPathComponent("/api/tags"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw WakeError.ollamaUnreachable("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return try JSONDecoder().decode(Resp.self, from: data).models.map {
            ModelInfo(name: $0.name, capabilities: $0.capabilities ?? [])
        }
    }

    /// Streams a chat completion; returns the full text (UI streams via callback).
    public func chatStream(model: String, messages: [(String, String)],
                           onDelta: (@Sendable (String) -> Void)? = nil) async throws -> String {
        struct Msg: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let messages: [Msg]
            let stream: Bool
            let think: Bool?
            let options: [String: JSONValue]?
        }
        enum JSONValue: Encodable {
            case double(Double)
            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                try c.encode(self)
            }
        }
        let body = Body(model: model,
                        messages: messages.map { Msg(role: $0.0, content: $0.1) },
                        stream: true, think: false,
                        options: ["temperature": .double(0.2)])
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/chat"))
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, resp) = try await session.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw WakeError.ollamaUnreachable("chat HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var full = ""
        var buffer = ""
        for try await byte in bytes {
            let ch = Character(UnicodeScalar(byte))
            if ch == "\n" {
                let line = buffer.trimmingCharacters(in: .whitespaces)
                buffer = ""
                guard !line.isEmpty, let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let content = (obj["message"] as? [String: Any])?["content"] as? String {
                    full += content
                    onDelta?(content)
                }
                if (obj["done"] as? Bool) == true { break }
            } else {
                buffer.append(ch)
            }
        }
        return full
    }
}

public enum WakeError: Error, CustomStringConvertible, Equatable {
    case ollamaUnreachable(String)
    case speechUnavailable(String)
    case permissionDenied(String)
    case invalidPlan(String)
    case modelMissing(String)
    case cancelled

    public var description: String {
        switch self {
        case .ollamaUnreachable(let m): return "Ollama unreachable: \(m)"
        case .speechUnavailable(let m): return "Local speech unavailable: \(m)"
        case .permissionDenied(let m): return "Permission denied: \(m)"
        case .invalidPlan(let m): return "Invalid action plan: \(m)"
        case .modelMissing(let m): return "No model supporting '\(m)' installed"
        case .cancelled: return "cancelled"
        }
    }
}
