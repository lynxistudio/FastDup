import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Internal row data structure for SQLite results
fileprivate struct RowData {
    let id: String
    let path: String
    let name: String
    let size: Int
    let modDate: Date
    let createDate: Date
    let ext: String
    let mime: String?
    let md5: String?
    let sha1: String?
    let resW: Int?
    let resH: Int?
    let dur: TimeInterval?
}

final class DatabaseManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbLock = NSRecursiveLock()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDir = appSupport.appendingPathComponent("FastDup")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("fastdup.sqlite").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_busy_timeout(db, 5000)

        let pragmas = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            "PRAGMA temp_store=MEMORY;"
        ]
        var stmt: OpaquePointer?
        for pragma in pragmas {
            if sqlite3_prepare_v2(db, pragma, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            stmt = nil
        }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS files (
            id TEXT PRIMARY KEY,
            path TEXT UNIQUE,
            name TEXT,
            size INTEGER,
            modification_date REAL,
            creation_date REAL,
            file_extension TEXT,
            mime_type TEXT,
            md5_hash TEXT,
            sha1_hash TEXT,
            resolution_width INTEGER,
            resolution_height INTEGER,
            duration REAL,
            directory TEXT
        );
        """
        if sqlite3_prepare_v2(db, createSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // Create indexes
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_files_md5 ON files(md5_hash);",
            "CREATE INDEX IF NOT EXISTS idx_files_sha1 ON files(sha1_hash);",
            "CREATE INDEX IF NOT EXISTS idx_files_name ON files(name);",
            "CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);",
            "CREATE INDEX IF NOT EXISTS idx_files_directory ON files(directory);",
            "CREATE INDEX IF NOT EXISTS idx_files_resolution ON files(resolution_width, resolution_height);",
            "CREATE INDEX IF NOT EXISTS idx_files_duration ON files(duration);"
        ]
        for idx in indexes {
            if sqlite3_prepare_v2(db, idx, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    deinit {
        dbLock.lock()
        defer { dbLock.unlock() }
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Upsert

    func upsert(_ file: FileItem, directory: String) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return }

        let sql = """
        INSERT OR REPLACE INTO files (id, path, name, size, modification_date, creation_date,
            file_extension, mime_type, md5_hash, sha1_hash, resolution_width, resolution_height, duration, directory)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        let idStr = file.id.uuidString
        sqlite3_bind_text(stmt, 1, idStr, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, file.path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, file.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, Int64(file.size))
        sqlite3_bind_double(stmt, 5, file.modificationDate.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, file.creationDate.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 7, file.fileExtension, -1, SQLITE_TRANSIENT)
        if let mime = file.mimeType {
            sqlite3_bind_text(stmt, 8, mime, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        if let md5 = file.md5Hash {
            sqlite3_bind_text(stmt, 9, md5, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let sha1 = file.sha1Hash {
            sqlite3_bind_text(stmt, 10, sha1, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if let res = file.resolution {
            sqlite3_bind_int(stmt, 11, Int32(res.width))
            sqlite3_bind_int(stmt, 12, Int32(res.height))
        } else {
            sqlite3_bind_null(stmt, 11)
            sqlite3_bind_null(stmt, 12)
        }
        if let dur = file.duration {
            sqlite3_bind_double(stmt, 13, dur)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        sqlite3_bind_text(stmt, 14, directory, -1, SQLITE_TRANSIENT)

        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func fileExists(path: String) -> Bool {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db else { return false }
        let sql = "SELECT 1 FROM files WHERE path = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        let exists = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return exists
    }

    func deleteFiles(inScanRoots roots: [String]) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db, !roots.isEmpty else { return }
        let clauses = roots.map { _ in "(directory = ? OR path = ? OR path LIKE ?)" }.joined(separator: " OR ")
        let sql = "DELETE FROM files WHERE \(clauses);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        var bindIdx: Int32 = 1
        for root in roots {
            sqlite3_bind_text(stmt, bindIdx, root, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, bindIdx + 1, root, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, bindIdx + 2, root + "/%", -1, SQLITE_TRANSIENT)
            bindIdx += 3
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func deleteFiles(paths: [String]) {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db, !paths.isEmpty else { return }
        let placeholders = paths.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM files WHERE path IN (\(placeholders));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for (i, path) in paths.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), path, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // MARK: - Incremental match (streaming)

    /// Find files in DB that match `file` on all active rule dimensions.
    /// Used for incremental/streaming duplicate detection.
    func findMatchesFor(file: FileItem, rule: SearchRule, dirs: [String]) -> [FileItem] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db, !dirs.isEmpty else { return [] }

        let ruleTypes = rule.ruleTypes
        let useMD5 = ruleTypes.contains(.exactHash)
        let useSHA1 = ruleTypes.contains(.exactHashSHA)
        let useName = ruleTypes.contains(.sameName)
        let useSize = ruleTypes.contains(.sameSize)
        let useExt = ruleTypes.contains(.sameExtension)
        let useRes = ruleTypes.contains(.sameResolution)
        let useDur = ruleTypes.contains(.sameDuration)

        guard !ruleTypes.isEmpty else { return [] }
        guard !useMD5 || file.md5Hash != nil else { return [] }
        guard !useSHA1 || file.sha1Hash != nil else { return [] }
        guard !useRes || file.resolution != nil else { return [] }
        guard !useDur || file.duration != nil else { return [] }

        let dirPlaceholders = dirs.map { _ in "?" }.joined(separator: ",")
        var conditions: [String] = ["directory IN (\(dirPlaceholders))", "id != ?"]

        if rule.minFileSize > 0 { conditions.append("size >= ?") }
        if !rule.excludedExtensions.isEmpty {
            let extPlaceholders = rule.excludedExtensions.map { _ in "?" }.joined(separator: ",")
            conditions.append("file_extension NOT IN (\(extPlaceholders))")
        }

        if useMD5, file.md5Hash != nil { conditions.append("md5_hash = ?") }
        if useSHA1, file.sha1Hash != nil { conditions.append("sha1_hash = ?") }
        if useName { conditions.append("name = ?") }
        if useSize { conditions.append("size = ?") }
        if useExt { conditions.append("file_extension = ?") }
        if useRes, file.resolution != nil {
            conditions.append("resolution_width = ? AND resolution_height = ?")
        }
        if useDur, file.duration != nil { conditions.append("duration = ?") }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = """
        SELECT id, path, name, size, modification_date, creation_date,
               file_extension, mime_type, md5_hash, sha1_hash,
               resolution_width, resolution_height, duration
        FROM files
        WHERE \(whereClause)
        LIMIT 50;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQL error: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }

        // Bind directory parameters
        var bindIdx: Int32 = 1
        for dir in dirs {
            sqlite3_bind_text(stmt, bindIdx, dir, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        // Bind self-exclusion
        sqlite3_bind_text(stmt, bindIdx, file.id.uuidString, -1, SQLITE_TRANSIENT)
        bindIdx += 1
        if rule.minFileSize > 0 {
            sqlite3_bind_int64(stmt, bindIdx, rule.minFileSize)
            bindIdx += 1
        }
        if !rule.excludedExtensions.isEmpty {
            for ext in rule.excludedExtensions {
                sqlite3_bind_text(stmt, bindIdx, ext, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
        }
        // Bind dimension values
        if useMD5, let md5 = file.md5Hash {
            sqlite3_bind_text(stmt, bindIdx, md5, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        if useSHA1, let sha1 = file.sha1Hash {
            sqlite3_bind_text(stmt, bindIdx, sha1, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        if useName {
            sqlite3_bind_text(stmt, bindIdx, file.name, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        if useSize {
            sqlite3_bind_int64(stmt, bindIdx, Int64(file.size))
            bindIdx += 1
        }
        if useExt {
            sqlite3_bind_text(stmt, bindIdx, file.fileExtension, -1, SQLITE_TRANSIENT)
            bindIdx += 1
        }
        if useRes, let res = file.resolution {
            sqlite3_bind_int(stmt, bindIdx, Int32(res.width))
            sqlite3_bind_int(stmt, bindIdx + 1, Int32(res.height))
            bindIdx += 2
        }
        if useDur, let dur = file.duration {
            sqlite3_bind_double(stmt, bindIdx, dur)
            bindIdx += 1
        }

        var results: [FileItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let item = fileItemFromRow(stmt)
            results.append(item)
        }
        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - Full duplicate group detection

    func findDupGroups(rule: SearchRule, dirs: [String]) -> [DuplicateGroup] {
        dbLock.lock()
        defer { dbLock.unlock() }
        guard let db = db, !dirs.isEmpty else { return [] }

        let ruleTypes = rule.ruleTypes
        let useMD5 = ruleTypes.contains(.exactHash)
        let useSHA1 = ruleTypes.contains(.exactHashSHA)
        let useName = ruleTypes.contains(.sameName)
        let useSize = ruleTypes.contains(.sameSize)
        let useExt = ruleTypes.contains(.sameExtension)
        let useRes = ruleTypes.contains(.sameResolution)
        let useDur = ruleTypes.contains(.sameDuration)

        // Build directory filter
        let dirPlaceholders = dirs.map { _ in "?" }.joined(separator: ",")
        var conditions: [String] = ["directory IN (\(dirPlaceholders))"]

        if rule.minFileSize > 0 {
            conditions.append("size >= \(rule.minFileSize)")
        }
        if !rule.excludedExtensions.isEmpty {
            let extPlaceholders = rule.excludedExtensions.map { _ in "?" }.joined(separator: ",")
            conditions.append("file_extension NOT IN (\(extPlaceholders))")
        }

        let whereClause = conditions.joined(separator: " AND ")

        // Determine GROUP BY columns
        var groupColumns: [String] = []
        if useMD5 { groupColumns.append("md5_hash") }
        if useSHA1 { groupColumns.append("sha1_hash") }
        if useName { groupColumns.append("name") }
        if useSize { groupColumns.append("size") }
        if useExt { groupColumns.append("file_extension") }
        if useRes { groupColumns.append("resolution_width, resolution_height") }
        if useDur { groupColumns.append("duration") }

        guard !groupColumns.isEmpty else { return [] }

        let groupBy = groupColumns.joined(separator: ", ")
        let sql = """
        SELECT id, path, name, size, modification_date, creation_date,
               file_extension, mime_type, md5_hash, sha1_hash,
               resolution_width, resolution_height, duration
        FROM files
        WHERE \(whereClause)
        ORDER BY \(groupBy), size DESC
        LIMIT 1000;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQL error: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }

        // Bind directory parameters
        for (i, dir) in dirs.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), dir, -1, SQLITE_TRANSIENT)
        }

        // Bind excluded extensions
        var bindIdx = dirs.count + 1
        if !rule.excludedExtensions.isEmpty {
            for ext in rule.excludedExtensions {
                sqlite3_bind_text(stmt, Int32(bindIdx), ext, -1, SQLITE_TRANSIENT)
                bindIdx += 1
            }
        }

        var allRows: [RowData] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            allRows.append(RowData(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                path: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                size: Int(sqlite3_column_int64(stmt, 3)),
                modDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                createDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                ext: String(cString: sqlite3_column_text(stmt, 6)),
                mime: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
                md5: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                sha1: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                resW: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 10)) : nil,
                resH: sqlite3_column_type(stmt, 11) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 11)) : nil,
                dur: sqlite3_column_type(stmt, 12) != SQLITE_NULL ? sqlite3_column_double(stmt, 12) : nil
            ))
        }
        sqlite3_finalize(stmt)

        // Group rows by the matching criteria
        var groups: [[RowData]] = []
        var used = Set<Int>()

        for i in 0..<allRows.count {
            if used.contains(i) { continue }
            var group: [RowData] = [allRows[i]]
            used.insert(i)

            for j in (i+1)..<allRows.count {
                if used.contains(j) { continue }
                var match = true
                if useMD5 { match = match && allRows[i].md5 == allRows[j].md5 && allRows[i].md5 != nil }
                if useSHA1 { match = match && allRows[i].sha1 == allRows[j].sha1 && allRows[i].sha1 != nil }
                if useName { match = match && allRows[i].name == allRows[j].name }
                if useSize { match = match && allRows[i].size == allRows[j].size }
                if useExt { match = match && allRows[i].ext == allRows[j].ext }
                if useRes { match = match && allRows[i].resW == allRows[j].resW && allRows[i].resH == allRows[j].resH && allRows[i].resW != nil }
                if useDur { match = match && allRows[i].dur == allRows[j].dur && allRows[i].dur != nil }
                if match {
                    group.append(allRows[j])
                    used.insert(j)
                }
            }

            if group.count >= 2 {
                groups.append(group)
            }
        }

        // Convert to DuplicateGroup
        var result: [DuplicateGroup] = []
        for group in groups {
            let files = group.sorted { $0.path < $1.path }.map { rowToFileItem($0) }
            let confidence: DuplicateGroup.Confidence
            let ruleCount = ruleTypes.count
            if ruleCount >= 3 { confidence = .high }
            else if ruleCount >= 2 { confidence = .medium }
            else { confidence = .low }

            result.append(DuplicateGroup(
                id: UUID(),
                files: files,
                matchingRules: ruleTypes,
                confidence: confidence
            ))
        }

        return result
    }

    // MARK: - Row → FileItem helpers

    private func fileItemFromRow(_ stmt: OpaquePointer!) -> FileItem {
        let idStr = String(cString: sqlite3_column_text(stmt, 0))
        let pathStr = String(cString: sqlite3_column_text(stmt, 1))
        let nameStr = String(cString: sqlite3_column_text(stmt, 2))
        let sizeVal = Int(sqlite3_column_int64(stmt, 3))
        let modDate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let createDate = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let extStr = String(cString: sqlite3_column_text(stmt, 6))
        let mimeStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let md5Str = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let sha1Str = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let resW: Int? = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 10)) : nil
        let resH: Int? = sqlite3_column_type(stmt, 11) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 11)) : nil
        let dur: TimeInterval? = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? sqlite3_column_double(stmt, 12) : nil

        let res: FileItem.Resolution? = {
            if let w = resW, let h = resH { return FileItem.Resolution(width: w, height: h) }
            return nil
        }()

        return FileItem(
            id: UUID(uuidString: idStr) ?? UUID(),
            path: pathStr, name: nameStr, size: sizeVal,
            modificationDate: modDate, creationDate: createDate,
            fileExtension: extStr, mimeType: mimeStr,
            md5Hash: md5Str, sha1Hash: sha1Str,
            resolution: res, duration: dur
        )
    }

    private func rowToFileItem(_ row: RowData) -> FileItem {
        let res: FileItem.Resolution? = {
            if let w = row.resW, let h = row.resH { return FileItem.Resolution(width: w, height: h) }
            return nil
        }()
        return FileItem(
            id: UUID(uuidString: row.id) ?? UUID(),
            path: row.path, name: row.name, size: row.size,
            modificationDate: row.modDate, creationDate: row.createDate,
            fileExtension: row.ext, mimeType: row.mime,
            md5Hash: row.md5, sha1Hash: row.sha1,
            resolution: res, duration: row.dur
        )
    }
}
