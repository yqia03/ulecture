import Foundation
import SQLite3

/// SQLite statements never interpolate user data; the connection is serialized by LibraryStore.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开资料库"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw LibraryError.message("SQLite: \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA foreign_keys=ON")
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA wal_autocheckpoint=256")
        }
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }

    /// SQLite's backup API captures committed WAL content without copying a live database file.
    func snapshot(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.message("快照目标已存在，未覆盖。") }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(url.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let destination else { throw LibraryError.message("无法创建数据库快照。") }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", handle, "main") else { throw LibraryError.message("无法开始数据库一致性快照。") }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw LibraryError.message("SQLite snapshot failed (step \(result), finish \(finished)): \(String(cString: sqlite3_errmsg(destination)))") }
        // Publish a self-contained snapshot: a WAL-mode header can require new sidecars even for a read-only consumer.
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw LibraryError.message("无法封存数据库快照。") }
    }

    func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw failure(code) }
    }

    func rows(_ sql: String, _ values: [String?] = []) throws -> [[String: String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw failure(code) }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                if let value = sqlite3_column_text(statement, index) { row[name] = String(cString: value) }
            }
            result.append(row)
        }
    }

    private func prepare(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw failure(code) }
        for (offset, value) in values.enumerated() {
            let bindCode: Int32
            if let value { bindCode = sqlite3_bind_text(statement, Int32(offset + 1), value, -1, Self.transient) }
            else { bindCode = sqlite3_bind_null(statement, Int32(offset + 1)) }
            if bindCode != SQLITE_OK { sqlite3_finalize(statement); throw failure(bindCode) }
        }
        return statement
    }
    private func failure(_ code: Int32) -> LibraryError {
        let detail: String
        switch code & 0xff {
        case SQLITE_FULL: detail = "磁盘空间不足；内容尚未保存。"
        case SQLITE_READONLY, SQLITE_PERM, SQLITE_AUTH: detail = "资料库不可写；内容尚未保存。"
        case SQLITE_IOERR, SQLITE_CANTOPEN: detail = "资料库目录失联或发生读写错误；内容尚未保存。"
        case SQLITE_CORRUPT, SQLITE_NOTADB: detail = "资料库损坏。请保留原目录并从备份恢复到新目录。"
        case SQLITE_BUSY, SQLITE_LOCKED: detail = "资料库正由其他操作占用；请重试。"
        default: detail = "资料库操作失败（SQLite \(code)）。"
        }
        return .message(detail)
    }
}
