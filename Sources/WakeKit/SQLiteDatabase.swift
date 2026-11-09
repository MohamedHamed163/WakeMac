import SQLite3
import Foundation

/// Minimal SQLite wrapper (same design as Notch Wiki's).
public final class SQLiteDatabase {
    private var db: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw NSError(domain: "WakeMac.sqlite", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
    }

    deinit { sqlite3_close_v2(db) }

    public func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw NSError(domain: "WakeMac.sqlite", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    public func run(_ sql: String, _ params: [Value] = []) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "WakeMac.sqlite", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "WakeMac.sqlite", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    public func queryAll(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "WakeMac.sqlite", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, params)
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var values: [Value?] = []
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL: values.append(nil)
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                default: values.append(nil)
                }
            }
            rows.append(Row(values: values, names: (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }))
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Value]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
    }

    public enum Value {
        case null, int(Int64), real(Double), text(String)
    }

    public struct Row {
        public let values: [Value?]
        public let names: [String]
        public func text(_ name: String) -> String? {
            guard let idx = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  case .text(let v)? = values[idx] else { return nil }
            return v
        }
        public func int(_ name: String) -> Int64? {
            guard let idx = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  case .int(let v)? = values[idx] else { return nil }
            return v
        }
        public func double(_ name: String) -> Double? {
            guard let idx = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  case .real(let v)? = values[idx] else { return nil }
            return v
        }
    }
}
