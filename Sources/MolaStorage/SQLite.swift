import Foundation
import SQLite3

/// 轻量 SQLite 封装（单连接 + 串行队列；调用方通过 actor 访问）。
public final class SQLiteDB: @unchecked Sendable {
    public enum DBError: Error, LocalizedError {
        case open(String), prepare(String, String), step(String)
        public var errorDescription: String? {
            switch self {
            case .open(let m): return "打开数据库失败：\(m)"
            case .prepare(let m, let sql): return "SQL 准备失败：\(m)（\(sql.prefix(80))）"
            case .step(let m): return "SQL 执行失败：\(m)"
            }
        }
    }

    public enum Value: Sendable {
        case null, int(Int64), double(Double), text(String)
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DBError.open(msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close(db) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DBError.step(msg)
        }
    }

    public var userVersion: Int {
        (try? query("PRAGMA user_version;") { $0.int(0) }.first) ?? 0
    }

    public func setUserVersion(_ v: Int) throws { try exec("PRAGMA user_version = \(v);") }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            let r = try body()
            try exec("COMMIT;")
            return r
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    public func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(errorMessage) }
        return Int(sqlite3_changes(db))
    }

    public func query<T>(_ sql: String, _ args: [Value] = [], map: (Row) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(Row(stmt: stmt!))) }
            else if rc == SQLITE_DONE { break }
            else { throw DBError.step(errorMessage) }
        }
        return out
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(errorMessage, sql)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            }
        }
        return stmt
    }

    public struct Row {
        let stmt: OpaquePointer
        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        public func stringOrNil(_ i: Int32) -> String? { isNull(i) ? nil : string(i) }
    }
}

extension SQLiteDB.Value {
    public static func of(_ s: String?) -> Self { s.map { .text($0) } ?? .null }
    public static func of(_ b: Bool) -> Self { .int(b ? 1 : 0) }
    public static func of(_ i: Int64) -> Self { .int(i) }
    public static func of(_ i: Int) -> Self { .int(Int64(i)) }
    public static func json<T: Encodable>(_ v: T) -> Self {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return (try? enc.encode(v)).map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null
    }
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ s: String?) -> T? {
    guard let s, !s.isEmpty else { return nil }
    return try? JSONDecoder().decode(T.self, from: Data(s.utf8))
}
