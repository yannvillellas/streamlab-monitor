import Foundation
import CSQLite

public enum StorageError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(path: String, message: String)
    case statementFailed(sql: String, message: String)
    case unsupportedSchemaVersion(found: Int64, supported: Int64)
    case corruptRow(sequence: Int64, message: String)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let message):
            "Cannot open \(path): \(message)"
        case .statementFailed(let sql, let message):
            "Statement failed: \(message) [\(sql)]"
        case .unsupportedSchemaVersion(let found, let supported):
            "Database schema version \(found) is newer than the supported \(supported)"
        case .corruptRow(let sequence, let message):
            "Stored payload at sequence \(sequence) is not a protocol message: \(message)"
        }
    }
}

/// One SQLite connection. Not thread-safe by itself: keep one instance to one owner.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public let path: String

    public init(path: String) throws {
        self.path = path

        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )

        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite status \(status)"
            if let connection { sqlite3_close_v2(connection) }
            throw StorageError.cannotOpen(path: path, message: message)
        }

        handle = connection
        sqlite3_busy_timeout(connection, 2_000)
        try execute("PRAGMA foreign_keys = ON")
    }

    /// A database that lives in memory, for tests and for a dry run.
    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// Closes the connection now instead of waiting for `deinit`.
    public func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    var rawHandle: OpaquePointer {
        guard let handle else {
            preconditionFailure("The database was used after close()")
        }
        return handle
    }

    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(rawHandle))
    }

    public func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(rawHandle, sql, nil, nil, &error)

        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw StorageError.statementFailed(sql: sql, message: message)
        }
    }

    public func scalarInt(_ sql: String) throws -> Int64? {
        let statement = try prepare(sql)
        defer { statement.reset() }
        guard try statement.step() else { return nil }
        return statement.int64(0)
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }
}

/// One prepared statement. It holds its connection alive and finalises on `deinit`,
/// so a thrown error in the middle of a read never leaks the handle.
final class SQLiteStatement {
    // `unsafeBitCast(-1, to:)` is the documented stand-in for SQLITE_TRANSIENT,
    // which is a C macro and has no Swift symbol.
    private var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private let database: SQLiteDatabase
    private var handle: OpaquePointer?

    init(database: SQLiteDatabase, sql: String) throws {
        self.database = database

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.rawHandle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StorageError.statementFailed(sql: sql, message: database.lastErrorMessage)
        }
        handle = statement
    }

    deinit {
        sqlite3_finalize(handle)
    }

    private var rawHandle: OpaquePointer {
        guard let handle else {
            preconditionFailure("The statement was finalised twice")
        }
        return handle
    }

    func bind(_ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(rawHandle, index, value, -1, transient) == SQLITE_OK else {
            throw StorageError.statementFailed(
                sql: "bind \(index)",
                message: database.lastErrorMessage
            )
        }
    }

    func bind(_ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(rawHandle, index, value) == SQLITE_OK else {
            throw StorageError.statementFailed(
                sql: "bind \(index)",
                message: database.lastErrorMessage
            )
        }
    }

    func bind(_ index: Int32, _ value: Double) throws {
        guard sqlite3_bind_double(rawHandle, index, value) == SQLITE_OK else {
            throw StorageError.statementFailed(
                sql: "bind \(index)",
                message: database.lastErrorMessage
            )
        }
    }

    func bindNull(_ index: Int32) throws {
        guard sqlite3_bind_null(rawHandle, index) == SQLITE_OK else {
            throw StorageError.statementFailed(
                sql: "bind \(index)",
                message: database.lastErrorMessage
            )
        }
    }

    /// Returns true when a row is available, false at the end of the result set.
    func step() throws -> Bool {
        let status = sqlite3_step(rawHandle)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw StorageError.statementFailed(
                sql: "step",
                message: database.lastErrorMessage
            )
        }
    }

    func reset() {
        sqlite3_reset(rawHandle)
        sqlite3_clear_bindings(rawHandle)
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(rawHandle, index) == SQLITE_NULL
    }

    func text(_ index: Int32) -> String {
        guard let value = sqlite3_column_text(rawHandle, index) else { return "" }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(rawHandle, index)
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(rawHandle, index)
    }
}

extension SQLiteDatabase {
    var lastInsertRowId: Int64 {
        sqlite3_last_insert_rowid(rawHandle)
    }
}
