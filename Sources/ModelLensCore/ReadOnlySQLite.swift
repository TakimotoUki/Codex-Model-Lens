import Foundation
import CSQLite

enum SQLiteReadError: Error, LocalizedError {
    case open(String), query(String)
    var errorDescription: String? {
        switch self {
        case .open(let text): "无法只读打开数据库：\(text)"
        case .query(let text): "数据库结构或查询不可用：\(text)"
        }
    }
}

// This wrapper has no write entry point. It is used only inside the scanner actor.
final class ReadOnlySQLite {
    private var db: OpaquePointer?
    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "文件不存在"
            if let db { sqlite3_close(db) }
            db = nil
            throw SQLiteReadError.open(message)
        }
        sqlite3_busy_timeout(db, 1000)
    }
    deinit { sqlite3_close(db) }

    func query(_ sql: String) throws -> [[String: String]] {
        var rows: [[String: String]] = []
        try forEach(sql) { rows.append($0) }; return rows
    }
    func forEach(_ sql: String, consume: ([String: String]) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteReadError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_stmt_readonly(stmt) != 0 else { throw SQLiteReadError.query("拒绝非只读查询") }
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SQLiteReadError.query(String(cString: sqlite3_errmsg(db))) }
            try autoreleasepool {
                var row: [String: String] = [:]
                for index in 0..<sqlite3_column_count(stmt) {
                    if sqlite3_column_type(stmt, index) == SQLITE_NULL { continue }
                    guard let value = sqlite3_column_text(stmt, index) else { continue }
                    row[String(cString: sqlite3_column_name(stmt, index))] = String(cString: value)
                }
                try consume(row)
            }
        }
    }

    func columns(_ table: String) throws -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        return Set(try query("PRAGMA table_info(\(table))").compactMap { $0["name"] })
    }
}
