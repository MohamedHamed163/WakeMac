import Foundation

/// Conversation + run history in SQLite (system library via WakeKit).
/// Modeled on the same thin-wrapper approach as the other products.
public struct HistoryEntry: Identifiable, Sendable, Codable {
    public var id: Int64
    public var timestamp: Date
    public var request: String
    public var response: String
    public var state: String
    public var planJSON: String
    public var resultsJSON: String
}

public final class HistoryStore: @unchecked Sendable {
    private var db: SQLiteDatabase?
    private let path: String
    private let queue = DispatchQueue(label: "wakemac.history")

    public init(path: String) {
        self.path = path
        open()
    }

    private func open() {
        do {
            let db = try SQLiteDatabase(path: path)
            try db.exec("""
            CREATE TABLE IF NOT EXISTS interactions(
                id INTEGER PRIMARY KEY,
                ts REAL NOT NULL,
                request TEXT NOT NULL,
                response TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL DEFAULT '',
                plan_json TEXT NOT NULL DEFAULT '{}',
                results_json TEXT NOT NULL DEFAULT '[]'
            );
            """)
            self.db = db
        } catch {
            self.db = nil
        }
    }

    public func append(request: String, response: String, state: String,
                       plan: ActionPlan?, results: [ActionResult]) {
        queue.sync {
            guard let db else { return }
            let planJSON = (try? JSONEncoder().encode(plan)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let resultsJSON = (try? JSONEncoder().encode(results)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try? db.run("INSERT INTO interactions(ts, request, response, state, plan_json, results_json) VALUES (?,?,?,?,?,?)",
                        [.real(Date().timeIntervalSince1970), .text(request), .text(response),
                         .text(state), .text(planJSON), .text(resultsJSON)])
        }
    }

    public func recent(limit: Int = 100) -> [HistoryEntry] {
        queue.sync {
            guard let db else { return [] }
            let rows = (try? db.queryAll("SELECT * FROM interactions ORDER BY id DESC LIMIT ?", [.int(Int64(limit))])) ?? []
            return rows.map {
                HistoryEntry(id: $0.int("id") ?? 0,
                             timestamp: Date(timeIntervalSince1970: $0.double("ts") ?? 0),
                             request: $0.text("request") ?? "",
                             response: $0.text("response") ?? "",
                             state: $0.text("state") ?? "",
                             planJSON: $0.text("plan_json") ?? "{}",
                             resultsJSON: $0.text("results_json") ?? "[]")
            }
        }
    }
}
