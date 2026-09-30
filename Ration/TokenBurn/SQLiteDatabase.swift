import Foundation
import SQLite3

enum SQLiteValue: Equatable, Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    var int: Int64 { if case .int(let value) = self { value } else { 0 } }
    var text: String { if case .text(let value) = self { value } else { "" } }
}

/// A thin SQLite connection. Not thread-safe: one owner uses it.
final class SQLiteDatabase {
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    private var handle: OpaquePointer?

    init(url: URL) throws {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path(percentEncoded: false), &db,
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw Failure(code: code, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    var changes: Int32 { handle.map { sqlite3_changes($0) } ?? 0 }

    func execute(_ sql: String) throws {
        guard let handle else { throw Failure(code: SQLITE_MISUSE, message: "closed") }
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw Failure(code: SQLITE_MISUSE, message: "closed") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        return SQLiteStatement(statement, database: self)
    }

    func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    private unowned let database: SQLiteDatabase
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    fileprivate init(_ handle: OpaquePointer, database: SQLiteDatabase) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    func run(_ values: [SQLiteValue] = []) throws {
        try bind(values)
        defer { sqlite3_reset(handle) }
        let code = sqlite3_step(handle)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw database.failure(code) }
    }

    func query(_ values: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try bind(values)
        defer { sqlite3_reset(handle) }
        var rows: [[SQLiteValue]] = []
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw database.failure(code) }
            rows.append((0..<sqlite3_column_count(handle)).map(column))
        }
    }

    private func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value {
            case .int(let v): sqlite3_bind_int64(handle, index, v)
            case .double(let v): sqlite3_bind_double(handle, index, v)
            // Explicit byte length: text is stored whole, NUL included.
            case .text(let v) where v.isEmpty: sqlite3_bind_text(handle, index, "", 0, Self.transient)
            case .text(let v):
                Array(v.utf8).withUnsafeBytes { raw in
                    sqlite3_bind_text(handle, index, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), Self.transient)
                }
            case .null: sqlite3_bind_null(handle, index)
            }
            guard code == SQLITE_OK else { throw database.failure(code) }
        }
    }

    private func column(_ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(handle, index) {
        case SQLITE_INTEGER: .int(sqlite3_column_int64(handle, index))
        case SQLITE_FLOAT: .double(sqlite3_column_double(handle, index))
        case SQLITE_TEXT:
            // Text first, then its byte count (SQLite's documented order).
            if let text = sqlite3_column_text(handle, index) {
                .text(String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(handle, index))), as: UTF8.self))
            } else {
                .text("")
            }
        default: .null
        }
    }
}
