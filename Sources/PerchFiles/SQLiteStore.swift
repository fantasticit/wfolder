import Foundation
import SQLite3

private enum SQLiteFailure: LocalizedError {
    case operation
    var errorDescription: String? { "无法读取或更新本机索引数据库。" }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(url: URL, writable: Bool) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        var handle: OpaquePointer?
        let result = url.withUnsafeFileSystemRepresentation { sqlite3_open_v2($0, &handle, flags, nil) }
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteFailure.operation
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 500)
    }

    deinit { sqlite3_close_v2(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFailure.operation }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteFailure.operation }
        return SQLiteStatement(statement)
    }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_finalize(handle) }

    func bind(_ value: Int, to index: Int32) throws {
        guard sqlite3_bind_int64(handle, index, Int64(value)) == SQLITE_OK else { throw SQLiteFailure.operation }
    }

    func bind(_ value: String, to index: Int32) throws {
        guard sqlite3_bind_text(handle, index, value, -1, Self.transient) == SQLITE_OK else { throw SQLiteFailure.operation }
    }

    func run() throws {
        guard sqlite3_step(handle) == SQLITE_DONE else { throw SQLiteFailure.operation }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func next() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteFailure.operation
        }
    }

    func integer(_ index: Int32) -> Int { Int(sqlite3_column_int64(handle, index)) }

    func string(_ index: Int32) -> String {
        sqlite3_column_text(handle, index).map { String(cString: $0) } ?? ""
    }
}
