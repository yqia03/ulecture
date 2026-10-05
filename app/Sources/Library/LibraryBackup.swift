import Foundation

enum ReadableExportSelection: String, CaseIterable {
    case notesAndSummaries, transcriptsAndTranslations, all
}

extension LibraryStore {
    /// A .uwaybackup directory contains versioned JSON plus whitelisted, hashed attachments.
    /// The directory is first built beside the destination and atomically renamed. Existing exports are never overwritten.
    func backup(itemID: String, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("目标已存在，请使用新名称，避免覆盖备份。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".uway-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        // SQLite facts are fixed briefly; managed attachments are immutable and never automatically deleted.
        // Large PDF/audio copies therefore do not hold the writer lock or stall ongoing incremental saves.
        let snapshot: (LibraryBackupManifest, [String:String]) = try withReadSnapshot {
            let scope = try backupScope(itemID: itemID)
            let ids = Set(scope.map { $0.id })
            var records: [PortableRecord] = []
            for row in try databaseRows("SELECT collection,id,owner_id,json FROM records ORDER BY rowid") {
                guard let owner = row["owner_id"], ids.contains(owner) else { continue }
                let value = PortableRecord(collection: row["collection"]!, id: row["id"]!, ownerID: owner, json: row["json"]!)
                try validateCollection(value.collection)
                records.append(value)
            }
            let includedAssets = try attachments().filter { ids.contains($0.ownerID) }
            let readable = try readableContents(scope: scope, selection: .all)
            return (LibraryBackupManifest(exportedAt: Date(), sourceLibraryID: libraryID, rootItemID: itemID,
                items: scope, records: records, attachments: includedAssets), readable)
        }
        let manifest = snapshot.0
        try writeReadableFiles(snapshot.1, to: staging.appendingPathComponent("readable"))
        try fm.createDirectory(at: staging.appendingPathComponent("attachments"), withIntermediateDirectories: false)
        for asset in manifest.attachments {
            let source = try managedURL(asset.relativePath)
            guard try Self.sha256(of: source) == asset.sha256 else { throw LibraryError.message("附件校验失败，备份未完成：\(asset.originalName)") }
            let target = try Self.safeChild(asset.relativePath, under: staging)
            try fm.copyItem(at: source, to: target)
            guard try Self.sha256(of: target) == asset.sha256 else { throw LibraryError.message("备份附件回读失败。") }
            let handle = try FileHandle(forWritingTo: target); try handle.synchronize(); try handle.close()
        }
        // JSONEncoder isn't shared across background backup and a concurrently running write operation.
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: manifestURL); try handle.synchronize(); try handle.close()
        try syncDirectory(staging.appendingPathComponent("attachments"))
        try syncDirectory(staging)
        try fm.moveItem(at: staging, to: destination)
        try syncDirectory(destination.deletingLastPathComponent())
    }

    @discardableResult
    func restoreBackup(from source: URL) throws -> [WorkspaceItem] {
        try checkWritable()
        let fm = FileManager.default
        let manifestURL = try Self.safeChild("manifest.json", under: source)
        let metadata = try fm.attributesOfItem(atPath: manifestURL.path)
        guard (metadata[.size] as? NSNumber)?.int64Value ?? Int64.max <= 256 * 1024 * 1024 else { throw LibraryError.message("备份清单过大，无法安全恢复。") }
        let manifest: LibraryBackupManifest
        do { manifest = try decoder.decode(LibraryBackupManifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw LibraryError.message("备份清单损坏或不完整；现有资料未修改。") }
        try validateBackup(manifest, root: source)
        var idMap: [String:String] = [:]
        for value in manifest.items { idMap[value.id] = UUID().uuidString }
        for value in manifest.attachments { idMap[value.id] = UUID().uuidString }
        // Include all embedded stable identities (capture epochs, summary snapshots, dispatches) before rewriting any record.
        for record in manifest.records {
            if idMap[record.id] == nil && UUID(uuidString: record.id) != nil { idMap[record.id] = UUID().uuidString }
            let object = try JSONSerialization.jsonObject(with: Data(record.json.utf8), options: [.fragmentsAllowed])
            collectUUIDs(object, map: &idMap)
        }
        var restored: [WorkspaceItem] = []
        for value in manifest.items {
            let data = try remapJSON(try encoder.encode(value), map: idMap)
            var item = try decoder.decode(WorkspaceItem.self, from: data)
            // All imported content is restored visible with fresh entity IDs. The selected root keeps a clear title.
            item.deletedAt = nil; item.deletionGroup = nil
            if value.id == manifest.rootItemID { item.title += "（恢复）" }
            item.updatedAt = Date()
            restored.append(item)
        }
        var copied: [URL] = []
        do {
            // Validate and copy immutable attachments before taking the database write lock.
            // Nothing is visible until the final transaction commits all related entities.
            var preparedAttachments: [ManagedAttachment] = []
            for asset in manifest.attachments {
                var copy = asset
                copy.id = idMap[asset.id]!
                copy.ownerID = idMap[asset.ownerID]!
                copy.relativePath = "attachments/\(copy.id).\(URL(fileURLWithPath: asset.relativePath).pathExtension)"
                let original = try Self.safeChild(asset.relativePath, under: source)
                let target = try managedURL(copy.relativePath)
                try fm.copyItem(at: original, to: target); copied.append(target)
                guard try Self.sha256(of: target) == copy.sha256 else { throw LibraryError.message("恢复附件回读校验失败。") }
                let handle = try FileHandle(forWritingTo: target); try handle.synchronize(); try handle.close()
                preparedAttachments.append(copy)
            }
            try syncDirectory(rootURL.appendingPathComponent("attachments"))
            var preparedRecords: [PortableRecord] = []
            for record in manifest.records {
                var mapped = record
                mapped.id = remapString(record.id, map: idMap)
                mapped.ownerID = idMap[record.ownerID]!
                var data = try remapJSON(Data(record.json.utf8), map: idMap)
                data = try InterpretationRecordValidation.suspend(data, collection: record.collection)
                if record.collection == "classrooms" {
                    var classroom = try decoder.decode(ClassroomRecord.self, from: data)
                    if classroom.state != "ended" && classroom.state != "draft" { classroom.state = "interrupted" }
                    classroom.translationUserPaused = true
                    data = try encoder.encode(classroom)
                } else if record.collection == "cloud-state" {
                    // Imported tasks must bind to an explicitly confirmed local service before any dispatch.
                    if var object = try JSONSerialization.jsonObject(with: data) as? [String:Any] {
                        object["translationUserPaused"] = true
                        if var jobs = object["jobs"] as? [[String:Any]] {
                            for index in jobs.indices {
                                jobs[index]["historical"] = true
                                if jobs[index]["status"] as? String == "running" {
                                    jobs[index]["status"] = "needsAttention"
                                    jobs[index]["errorCode"] = "restoredRequestOutcomeUnknown"
                                }
                            }
                            object["jobs"] = jobs
                        }
                        data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    }
                }
                mapped.json = String(decoding: data, as: UTF8.self)
                preparedRecords.append(mapped)
            }
            try withTransaction {
                // Topological insertion satisfies parent foreign keys regardless of manifest ordering.
                var pending = restored
                var written: Set<String> = []
                while !pending.isEmpty {
                    let ready = pending.filter { $0.parentID == nil || written.contains($0.parentID!) }
                    guard !ready.isEmpty else { throw LibraryError.message("备份包含循环层级。") }
                    for value in ready { try writeItem(value); written.insert(value.id) }
                    pending.removeAll { written.contains($0.id) }
                }
                for attachment in preparedAttachments { try writeAttachment(attachment) }
                for record in preparedRecords { try writePortableRecord(record) }
            }
            return restored
        } catch {
            for url in copied { try? fm.removeItem(at: url) }
            throw error
        }
    }

    func exportReadable(itemID: String, to destination: URL, selection: ReadableExportSelection = .all) throws {
        let files = try withReadSnapshot { try readableContents(scope: backupScope(itemID: itemID), selection: selection) }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("导出位置已存在，请选择新文件夹。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".uway-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try writeReadableFiles(files, to: staging)
        try fm.moveItem(at: staging, to: destination)
    }

    private func backupScope(itemID: String) throws -> [WorkspaceItem] {
        let all = try items(includeDeleted: true)
        guard let root = all.first(where: { $0.id == itemID && $0.deletedAt == nil }) else { throw LibraryError.message("所选导出资料不存在或已删除。") }
        if root.kind != .classroom, let classroomID = root.classroomID {
            return try backupScope(itemID: classroomID)
        }
        var selected = [root] + descendantsOf(root.id, in: all)
        selected = selected.filter { $0.deletedAt == nil }
        // A single classroom backup includes a minimal course container, never unrelated siblings.
        if root.kind == .classroom, let courseID = root.courseID, let course = all.first(where: { $0.id == courseID }) {
            selected[0].parentID = course.id
            selected.insert(course, at: 0)
        } else if root.kind != .course {
            selected[0].parentID = nil
            // Standalone folder/note exports detach organization, but classroom ownership is never detached.
            if !selected.contains(where: { $0.kind == .classroom }) {
                for index in selected.indices { selected[index].courseID = nil }
            } else if let courseID = root.courseID, let course = all.first(where: { $0.id == courseID }) {
                selected[0].parentID = course.id; selected.insert(course, at: 0)
            }
        }
        return selected
    }

    private func validateBackup(_ manifest: LibraryBackupManifest, root: URL) throws {
        guard manifest.format == "uway-portable-library", manifest.version == 1,
              !manifest.items.isEmpty, manifest.items.count <= 100_000, manifest.records.count <= 1_000_000,
              manifest.attachments.count <= 100_000 else { throw LibraryError.message("不支持此备份格式或备份规模。") }
        let ids = Set(manifest.items.map { $0.id })
        guard ids.count == manifest.items.count, ids.contains(manifest.rootItemID), ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw LibraryError.message("备份包含重复或无效身份。") }
        let byID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id,$0) })
        for item in manifest.items {
            guard item.parentID == nil || ids.contains(item.parentID!), item.courseID == nil || byID[item.courseID!]?.kind == .course,
                  item.classroomID == nil || byID[item.classroomID!]?.kind == .classroom else { throw LibraryError.message("备份组织关系缺失。") }
            if item.kind == .course { guard item.parentID == nil && item.courseID == item.id else { throw LibraryError.message("备份课程层级无效。") } }
            if item.kind == .classroom { guard item.courseID != nil, item.classroomID == item.id else { throw LibraryError.message("备份课堂缺少所属课程。") } }
            if let parentID = item.parentID, let parent = byID[parentID] {
                guard [.course,.folder,.classroom].contains(parent.kind), parent.kind != .classroom || [.pdf,.note].contains(item.kind) else { throw LibraryError.message("备份层级不合法。") }
                let expectedCourse = parent.kind == .course ? parent.id : parent.courseID
                guard item.courseID == expectedCourse else { throw LibraryError.message("备份课程关系不一致。") }
                if parent.kind == .classroom { guard item.classroomID == parent.id else { throw LibraryError.message("备份课堂附件归属不一致。") } }
            }
            var seen: Set<String> = [item.id], cursor = item.parentID
            while let id = cursor { guard seen.insert(id).inserted else { throw LibraryError.message("备份包含循环层级。") }; cursor = byID[id]?.parentID }
        }
        let assetIDs = Set(manifest.attachments.map { $0.id })
        guard assetIDs.count == manifest.attachments.count else { throw LibraryError.message("备份附件身份重复。") }
        var paths: Set<String> = []
        for asset in manifest.attachments {
            guard UUID(uuidString: asset.id) != nil, ids.contains(asset.ownerID), asset.byteCount > 0,
                  asset.relativePath.hasPrefix("attachments/"), paths.insert(asset.relativePath).inserted,
                  ["pdf","caf","wav","m4a"].contains(URL(fileURLWithPath: asset.relativePath).pathExtension.lowercased()),
                  asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit }) else { throw LibraryError.message("备份附件清单无效。") }
            let url = try Self.safeChild(asset.relativePath, under: root)
            let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
            guard metadata[.type] as? FileAttributeType == .typeRegular, (metadata[.size] as? NSNumber)?.int64Value == asset.byteCount,
                  try Self.sha256(of: url) == asset.sha256 else { throw LibraryError.message("备份附件不完整或校验失败：\(asset.originalName)") }
        }
        for item in manifest.items where item.kind == .pdf {
            guard let assetID = item.assetID, assetIDs.contains(assetID), manifest.attachments.first(where: { $0.id == assetID })?.ownerID == item.id else { throw LibraryError.message("PDF 依赖不完整。") }
        }
        var records: Set<String> = []
        for record in manifest.records {
            try validateCollection(record.collection)
            guard ids.contains(record.ownerID), records.insert(record.collection + "\0" + record.id).inserted else { throw LibraryError.message("备份记录重复或归属缺失。") }
            _ = try JSONSerialization.jsonObject(with: Data(record.json.utf8), options: [.fragmentsAllowed])
            try InterpretationRecordValidation.portable(record) { byID[$0]?.kind == .classroom }
            switch record.collection {
            case "classrooms":
                let value = try decode(ClassroomRecord.self, record.json)
                guard value.id == record.ownerID, byID[value.id]?.kind == .classroom else { throw LibraryError.message("备份课堂记录无效。") }
            case "transcripts":
                let value = try decode(TranscriptRecord.self, record.json)
                guard value.classroomID == record.ownerID, byID[value.classroomID]?.kind == .classroom, value.startMS >= 0, value.endMS >= value.startMS else { throw LibraryError.message("备份原文时间或归属无效。") }
            case "note-revisions":
                let value = try decode(NoteRevision.self, record.json)
                guard value.noteID == record.ownerID, byID[value.noteID]?.kind == .note, value.classroomID == byID[value.noteID]?.classroomID else { throw LibraryError.message("备份笔记引用不完整。") }
            case "pdf-pages":
                let value = try decode(PDFTextPage.self, record.json)
                guard value.pageNumber > 0, assetIDs.contains(value.assetID), byID[record.ownerID]?.assetID == value.assetID else { throw LibraryError.message("备份 PDF 页码引用无效。") }
            case "recordings":
                let value = try decode(RecordingRecord.self, record.json)
                guard value.classroomID == record.ownerID, assetIDs.contains(value.assetID), value.startMS >= 0, value.endMS > value.startMS else { throw LibraryError.message("备份录音映射不完整。") }
            default: break
            }
        }
        try validateCloudReferences(manifest)
        // No unlisted payloads are copied or run. Executable and symlink payloads anywhere are rejected.
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey,.isExecutableKey]) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey,.isExecutableKey])
                guard values.isSymbolicLink != true else { throw LibraryError.message("备份含符号链接，已拒绝。") }
                if values.isRegularFile == true && values.isExecutable == true { throw LibraryError.message("备份含可执行内容，已拒绝。") }
            }
        }
    }

    private func readableContents(scope: [WorkspaceItem], selection: ReadableExportSelection) throws -> [String:String] {
        var files: [String:String] = [:]
        let ids = Set(scope.map { $0.id })
        let exportInfo = "# ULecture 可读导出\n\nUTF-8。本地转写保留采集时间轴，暂停和间断不压缩。在线同传的原文与译文为独立轨道；时间依据逐条标明，缺少时间时只导出文字，不生成字幕时间。译文仅包含已保存结果。Markdown 中页码引用保留稳定附件身份。\n\n" + scope.map { "- \($0.kind.rawValue): \($0.title) [\($0.id)]" }.joined(separator: "\n")
        files["README.md"] = exportInfo
        for item in scope where item.kind == .note && selection != .transcriptsAndTranslations {
            if let revision = try noteRevision(noteID: item.id) {
                files["note-\(item.id).md"] = "# \(item.title)\n\n" + revision.markdown
            }
        }
        for item in scope where item.kind == .classroom && selection != .notesAndSummaries {
            if let online = try interpretationExportText(sessionID: item.id, format: .txt, bilingual: true) {
                files["transcript-\(item.id).txt"] = online
                // Untimed online text remains exportable without inventing speech timestamps.
                for track in ["source", "translation"] {
                    if let timed = try? interpretationExportText(sessionID: item.id, format: .srt, bilingual: true, track: track) { files["subtitles-\(item.id)-\(track).srt"] = timed }
                    if let timed = try? interpretationExportText(sessionID: item.id, format: .vtt, bilingual: true, track: track) { files["subtitles-\(item.id)-\(track).vtt"] = timed }
                }
                continue
            }
            let transcript = try transcripts(classroomID: item.id)
            let translations = try savedTranslations(classroomID: item.id)
            let text = transcript.map { segment in
                "[\(Self.subtitleTime(segment.startMS, separator: ".")) – \(Self.subtitleTime(segment.endMS, separator: "."))] \(segment.language)\n\(segment.text)" + (translations[segment.id].map { "\nzh: \($0)" } ?? "\n[译文尚未保存]")
            }.joined(separator: "\n\n")
            files["transcript-\(item.id).txt"] = text
            let srt = transcript.enumerated().map { index, segment in
                "\(index + 1)\n\(Self.subtitleTime(segment.startMS, separator: ",")) --> \(Self.subtitleTime(segment.endMS, separator: ","))\n\(segment.text)" + (translations[segment.id].map { "\n\($0)" } ?? "") + "\n"
            }.joined(separator: "\n")
            files["subtitles-\(item.id).srt"] = srt
            let vtt = "WEBVTT\n\n" + transcript.enumerated().map { index, segment in
                "\(index + 1)\n\(Self.subtitleTime(segment.startMS, separator: ".")) --> \(Self.subtitleTime(segment.endMS, separator: "."))\n\(segment.text)" + (translations[segment.id].map { "\n\($0)" } ?? "") + "\n"
            }.joined(separator: "\n")
            files["subtitles-\(item.id).vtt"] = vtt
        }
        // Cloud summaries remain separate from user notes; recognized saved Markdown is exported with its AI label.
        for row in try databaseRows("SELECT collection,id,owner_id,json FROM records") where ids.contains(row["owner_id"] ?? "") && selection != .transcriptsAndTranslations {
            if row["collection"] == "cloud-state",
               let object = try JSONSerialization.jsonObject(with: Data(row["json"]!.utf8)) as? [String:Any],
               let summaries = object["summaries"] as? [[String:Any]] {
                for summary in summaries {
                    let snapshot = summary["snapshot"] as? [String:Any] ?? [:]
                    let claims = summary["claims"] as? [[String:Any]] ?? []
                    let sources = snapshot["sources"] as? [[String:Any]] ?? []
                    var markdown = "# AI 生成总结\n\n状态：" + (summary["status"] as? String ?? "未知")
                    markdown += "\n快照：" + (snapshot["id"] as? String ?? "未知")
                    markdown += "\n未完成分块：\((summary["missingChunkIDs"] as? [String] ?? []).count)\n\n"
                    markdown += claims.map { claim in
                        "- " + (claim["text"] as? String ?? "") + " " + (claim["referenceIDs"] as? [String] ?? []).map { "[来源 \($0)]" }.joined(separator: " ")
                    }.joined(separator: "\n\n")
                    markdown += "\n\n## 固定来源快照\n\n"
                    for source in sources {
                        markdown += "### " + (source["id"] as? String ?? "未知") + "\n\n"
                        markdown += "类型：\(source["kind"] as? String ?? "未知") · 实体：\(source["entityID"] as? String ?? "未知") · 版本：\(source["version"] as? Int ?? 0)"
                        if let page = source["page"] as? Int { markdown += " · PDF 物理页：\(page)" }
                        if let start = source["startMS"] as? Int64 { markdown += " · 时间：\(Self.subtitleTime(start, separator: "."))" }
                        markdown += "\n\n" + (source["text"] as? String ?? "") + "\n\n"
                    }
                    let exclusions = snapshot["excluded"] as? [String] ?? []
                    if !exclusions.isEmpty { markdown += "## 未分析范围\n\n" + exclusions.map { "- " + $0 }.joined(separator: "\n") }
                    files["summary-\(UUID().uuidString).md"] = markdown
                }
            }
            if row["collection"] == "summaries" || row["collection"] == "summary-results" {
                if let object = try JSONSerialization.jsonObject(with: Data(row["json"]!.utf8)) as? [String:Any], let markdown = object["markdown"] as? String ?? object["text"] as? String {
                    files["summary-\(UUID().uuidString).md"] = "# AI 生成总结\n\n" + markdown
                }
            }
        }
        return files
    }

    private func writeReadableFiles(_ files: [String:String], to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: destination.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }

    private func savedTranslations(classroomID: String) throws -> [String:String] {
        var translations: [String:String] = [:]
        // Traverse the persisted cloud state and support separate result records without a dependency on a cloud module.
        func inspect(_ object: Any) {
            if let object = object as? [String:Any] {
                let segmentID = object["segmentID"] as? String ?? object["transcriptID"] as? String
                let translated = object["translation"] as? String ?? object["translatedText"] as? String ?? (object["sourceRevision"] != nil ? object["text"] as? String : nil)
                if let segmentID, let translated, !translated.isEmpty { translations[segmentID] = translated }
                // The production cloud state keeps results inside jobs; obsolete results are excluded.
                if let jobs = object["jobs"] as? [[String:Any]] {
                    for job in jobs where job["status"] as? String == "completed" { if let result = job["translation"] { inspect(result) } }
                } else { for value in object.values { inspect(value) } }
            } else if let array = object as? [Any] { for value in array { inspect(value) } }
        }
        for row in try databaseRows("SELECT json FROM records WHERE owner_id=? AND collection IN ('cloud-state','translations','translation-results')", [classroomID]) {
            inspect(try JSONSerialization.jsonObject(with: Data(row["json"]!.utf8)))
        }
        return translations
    }

    private func validateCloudReferences(_ manifest: LibraryBackupManifest) throws {
        let items = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        let assets = Dictionary(uniqueKeysWithValues: manifest.attachments.map { ($0.id, $0) })
        let transcripts = try manifest.records.filter { $0.collection == "transcripts" }.map { try decode(TranscriptRecord.self, $0.json) }
        let revisions = try manifest.records.filter { $0.collection == "note-revisions" }.map { try decode(NoteRevision.self, $0.json) }
        let pages = try manifest.records.filter { $0.collection == "pdf-pages" }.map { try decode(PDFTextPage.self, $0.json) }
        for record in manifest.records where record.collection == "cloud-state" {
            guard let object = try JSONSerialization.jsonObject(with: Data(record.json.utf8)) as? [String:Any], object["classID"] as? String == record.ownerID, record.id == record.ownerID else { throw LibraryError.message("云任务课堂归属无效。") }
            for job in object["jobs"] as? [[String:Any]] ?? [] {
                guard let segment = job["segment"] as? [String:Any], let id = segment["id"] as? String,
                      segment["classID"] as? String == record.ownerID,
                      transcripts.contains(where: { $0.id == id && $0.classroomID == record.ownerID }) else { throw LibraryError.message("翻译任务的原文引用缺失。") }
                if let translation = job["translation"] as? [String:Any] {
                    guard translation["segmentID"] as? String == id,
                          translation["classID"] as? String == record.ownerID,
                          translation["sourceRevision"] as? Int == segment["revision"] as? Int,
                          translation["id"] as? String == job["id"] as? String,
                          translation["targetLanguage"] as? String == job["targetLanguage"] as? String,
                          let dispatch = translation["dispatch"] as? [String:Any],
                          let dispatchID = dispatch["id"] as? String, let version = dispatch["version"] as? Int,
                          let dispatched = (job["dispatches"] as? [[String:Any]])?.first(where: { $0["id"] as? String == dispatchID }),
                          NSDictionary(dictionary: dispatch).isEqual(to: dispatched),
                          (job["status"] as? String != "completed" || version == job["dispatchVersion"] as? Int)
                    else { throw LibraryError.message("备份译文与原文或派发版本不一致。") }
                } else if job["status"] as? String == "completed" { throw LibraryError.message("已完成翻译缺少译文。") }
            }
            for summary in object["summaries"] as? [[String:Any]] ?? [] {
                guard let snapshot = summary["snapshot"] as? [String:Any], snapshot["classID"] as? String == record.ownerID,
                      let sources = snapshot["sources"] as? [[String:Any]] else { throw LibraryError.message("总结来源快照无效。") }
                var sourceIDs: Set<String> = []
                var sourceLengths: [String:Int] = [:]
                for source in sources {
                    guard let id = source["id"] as? String, sourceIDs.insert(id).inserted,
                          let entityID = source["entityID"] as? String, let version = source["version"] as? Int,
                          version > 0, let text = source["text"] as? String else { throw LibraryError.message("总结来源身份或版本无效。") }
                    sourceLengths[id] = text.count
                    switch source["kind"] as? String {
                    case "pdf":
                        guard let asset = assets[entityID], items[asset.ownerID]?.classroomID == record.ownerID,
                              let page = source["page"] as? Int,
                              pages.contains(where: { $0.assetID == entityID && $0.version == version && $0.pageNumber == page && $0.text == text }) else { throw LibraryError.message("总结 PDF 来源不存在或文字版本不符。") }
                    case "note":
                        guard revisions.contains(where: { ($0.noteID == entityID || $0.id == entityID) && $0.classroomID == record.ownerID && $0.version == version && $0.markdown == text }) else { throw LibraryError.message("总结笔记固定版本缺失。") }
                    case "transcript":
                        guard let original = transcripts.first(where: { $0.id == entityID && $0.classroomID == record.ownerID && $0.revision >= version }),
                              let start = source["startMS"] as? Int64, let end = source["endMS"] as? Int64, start >= 0, end >= start,
                              (original.revision != version || (original.text == text && original.startMS == start && original.endMS == end))
                        else { throw LibraryError.message("总结原文来源或时间无效。") }
                        if let classRecord = manifest.records.first(where: { $0.collection == "classrooms" && $0.ownerID == record.ownerID }),
                           end > (try decode(ClassroomRecord.self, classRecord.json)).timelineMilliseconds { throw LibraryError.message("总结原文来源或时间无效。") }
                    default: throw LibraryError.message("未知总结来源类型。")
                    }
                }
                for claim in summary["claims"] as? [[String:Any]] ?? [] {
                    guard (claim["referenceIDs"] as? [String] ?? []).allSatisfy({ sourceIDs.contains($0) }) else { throw LibraryError.message("总结引用指向快照外来源。") }
                }
                let chunks = summary["chunks"] as? [[String:Any]] ?? []
                let chunkIDs = chunks.compactMap { $0["id"] as? String }
                let completedIDs = summary["completedChunkIDs"] as? [String] ?? []
                let missingIDs = summary["missingChunkIDs"] as? [String] ?? []
                let completed = Set(completedIDs), missing = Set(missingIDs)
                guard Set(chunkIDs).count == chunks.count, completed.count == completedIDs.count, missing.count == missingIDs.count,
                      completed.isDisjoint(with: missing), completed.union(missing) == Set(chunkIDs),
                      chunks.allSatisfy({ chunk in
                          guard let id = chunk["id"] as? String else { return false }
                          return (chunk["status"] as? String == "completed") == completed.contains(id)
                      }) else { throw LibraryError.message("总结分块完成清单不一致。") }
                for chunk in summary["chunks"] as? [[String:Any]] ?? [] {
                    for span in chunk["spans"] as? [[String:Any]] ?? [] {
                        guard let id = span["sourceID"] as? String, let length = sourceLengths[id],
                              let start = span["startCharacter"] as? Int, let count = span["characterCount"] as? Int,
                              start >= 0, count > 0, start <= length, count <= length - start else { throw LibraryError.message("总结分块覆盖超出来源范围。") }
                    }
                }
            }
        }
    }

    static func subtitleTime(_ milliseconds: Int64, separator: String) -> String {
        let value = max(0, milliseconds)
        return String(format: "%02lld:%02lld:%02lld%@%03lld", value / 3_600_000, value / 60_000 % 60, value / 1_000 % 60, separator, value % 1_000)
    }
    private func collectUUIDs(_ value: Any, map: inout [String:String]) {
        if let value = value as? String {
            let regex = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                if let range = Range(match.range, in: value) { let id = String(value[range]); if map[id] == nil { map[id] = map.first(where: { $0.key.caseInsensitiveCompare(id) == .orderedSame })?.value ?? UUID().uuidString } }
            }
        } else if let dictionary = value as? [String:Any] { for (key,value) in dictionary { collectUUIDs(key, map: &map); collectUUIDs(value, map: &map) } }
        else if let array = value as? [Any] { for value in array { collectUUIDs(value, map: &map) } }
    }
    private func remapString(_ value: String, map: [String:String]) -> String {
        var result = value
        for key in map.keys.sorted(by: { $0.count > $1.count }) { result = result.replacingOccurrences(of: key, with: map[key]!, options: .caseInsensitive) }
        return result
    }
    private func remapJSON(_ data: Data, map: [String:String]) throws -> Data {
        func visit(_ value: Any, field: String? = nil) throws -> Any {
            if let string = value as? String {
                if InterpretationRecordValidation.opaqueFields.contains(field ?? "") { return string }
                if ["text", "markdown", "title", "originalName", "limitation", "reason", "notice"].contains(field ?? "") {
                    // Preserve user/AI prose byte-for-byte except the app's explicit local PDF link scheme.
                    var preserved = string
                    if field == "text" || field == "markdown" {
                        for (old, new) in map { preserved = preserved.replacingOccurrences(of: "uway-pdf://" + old, with: "uway-pdf://" + new, options: .caseInsensitive) }
                    }
                    return preserved
                }
                return remapString(string, map: map)
            }
            if let dictionary = value as? [String:Any] {
                var remapped: [String:Any] = [:]
                for (key, value) in dictionary {
                    let nextKey = remapString(key, map: map)
                    guard remapped[nextKey] == nil else { throw LibraryError.message("备份包含重复或无效身份。") }
                    remapped[nextKey] = try visit(value, field: key)
                }
                return remapped
            }
            if let array = value as? [Any] { return try array.map { try visit($0, field: field) } }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: visit(object), options: [.sortedKeys,.fragmentsAllowed])
    }
}
