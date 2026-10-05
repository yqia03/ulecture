import Foundation

enum TranscriptExportFormat: String, CaseIterable { case txt, md, srt, vtt }

/// The automatic TXT and explicit exports share the same rendering rules.
enum TranscriptTextFormatter {
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func translations(rows: [TranscriptRecord], cloudJSON: [String], targetLanguage: String? = nil) throws -> [String: String] {
        var expected: [String: Int] = [:]
        for row in rows {
            guard expected.updateValue(row.revision, forKey: row.id) == nil else { throw LibraryError.message("会话包含无效或其他所有者记录。") }
        }
        var result: [String: String] = [:]
        for json in cloudJSON {
            if let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let jobs = object["jobs"] as? [[String: Any]] {
                for job in jobs where job["status"] as? String == "completed" {
                    if let value = job["translation"] as? [String: Any], let id = value["segmentID"] as? String,
                       let revision = value["sourceRevision"] as? Int, expected[id] == revision, let text = value["text"] as? String {
                        if let targetLanguage {
                            guard value["targetLanguage"] as? String == targetLanguage,
                                  (job["targetLanguage"] as? String).map({ $0 == targetLanguage }) ?? true else { continue }
                        }
                        result[id] = normalized(text)
                    }
                }
            }
        }
        return result
    }

    static func local(rows: [TranscriptRecord], translations: [String: String], format: TranscriptExportFormat) -> String {
        let blocks = rows.enumerated().map { index, row -> String in
            let text = normalized(row.text) + (translations[row.id].map { "\n" + $0 } ?? "")
            switch format {
            case .txt, .md: return "[\(LibraryStore.subtitleTime(row.startMS, separator: ".")) – \(LibraryStore.subtitleTime(row.endMS, separator: "."))]\n" + text
            case .srt, .vtt:
                let separator = format == .srt ? "," : "."
                return "\(index + 1)\n\(LibraryStore.subtitleTime(row.startMS, separator: separator)) --> \(LibraryStore.subtitleTime(row.endMS, separator: separator))\n" + text
            }
        }
        return (format == .vtt ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
    }

    static func online(rows: [InterpretationCaptionRecord], format: TranscriptExportFormat) throws -> String {
        let timed = format == .srt || format == .vtt
        if timed, rows.contains(where: { $0.startMS == nil || $0.endMS == nil || $0.endMS! <= $0.startMS! || $0.timingSource == "unknown" }) {
            throw LibraryError.message("interpretation.untimedSubtitleExport")
        }
        let blocks = rows.enumerated().map { index, row -> String in
            let track = row.track == "source" ? "Source" : "Translation"
            let completion: String
            switch row.completionBasis {
            case "provider": completion = row.isFinal ? " · provider final" : " · partial"
            case "localBoundary": completion = " · local segment boundary"
            case "sessionClosed": completion = " · session closed"
            case "interrupted": completion = " · interrupted"
            default: completion = " · partial"
            }
            let timing = row.timingSource == "provider" ? "provider timing" : row.timingSource == "unknown" ? "untimed" : "estimated display timing"
            let label = "[\(track) · \(row.language) · \(timing)\(completion)]"
            let text = normalized(row.text)
            if timed {
                let separator = format == .srt ? "," : "."
                return "\(index + 1)\n\(LibraryStore.subtitleTime(row.startMS!, separator: separator)) --> \(LibraryStore.subtitleTime(row.endMS!, separator: separator))\n" + label + "\n" + text
            }
            return label + "\n" + text
        }
        return (format == .vtt ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
    }

    static func session(_ session: WorkspaceItem, records: [PortableRecord]) throws -> Data {
        try sessionFiles(session, records: records)[.bilingual]!
    }

    static func sessionFiles(_ session: WorkspaceItem, records: [PortableRecord]) throws -> [TranscriptTextKind: Data] {
        let decoder = JSONDecoder()
        var rows: [TranscriptRecord] = try records.filter { $0.collection == "transcripts" }.map { record in
            let value = try decoder.decode(TranscriptRecord.self, from: Data(record.json.utf8))
            guard value.id == record.id, value.classroomID == session.id else { throw LibraryError.message("会话包含无效或其他所有者记录。") }
            return value
        }
        rows.sort {
            $0.startMS == $1.startMS ? $0.id < $1.id : $0.startMS < $1.startMS
        }
        var captions: [InterpretationCaptionRecord] = try records.filter { $0.collection == "interpretation-captions" }.map { record in
            let value = try decoder.decode(InterpretationCaptionRecord.self, from: Data(record.json.utf8))
            guard value.id == record.id, value.sessionID == session.id else { throw LibraryError.message("会话包含无效或其他所有者记录。") }
            return value
        }
        captions.sort {
            if $0.receivedAtMS != $1.receivedAtMS { return $0.receivedAtMS < $1.receivedAtMS }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
        let classroom = try records.first(where: { $0.collection == "classrooms" }).map { try decoder.decode(ClassroomRecord.self, from: Data($0.json.utf8)) }
        let translated = try translations(rows: rows, cloudJSON: records.filter { $0.collection == "cloud-state" }.map(\.json), targetLanguage: classroom?.targetLanguage)
        return try Dictionary(uniqueKeysWithValues: TranscriptTextKind.allCases.map { kind in
            var parts = [normalized(session.title)]
            if !rows.isEmpty { parts.append(local(rows: rows, translations: kind == .bilingual ? translated : [:], format: .txt)) }
            let trackRows = captions.filter { kind == .bilingual || $0.track == "source" }
            if !trackRows.isEmpty { parts.append(try online(rows: trackRows, format: .txt)) }
            return (kind, Data((parts.joined(separator: "\n\n") + (parts.count == 1 ? "\n" : "")).utf8))
        })
    }
}

extension LibraryStore {
    func transcriptSessions(for itemID: String) throws -> [WorkspaceItem] {
        guard let selected = try item(id: itemID) else { return [] }
        let all = try items(includeDeleted: true)
        let scope = [selected] + descendantsOf(itemID, in: all)
        let documentIDs = Set(scope.map(\.id))
        var ids = Set(scope.filter { $0.kind == .classroom }.map(\.id))
        ids.formUnion(scope.compactMap(\.classroomID))
        for link in try records(collection: "session-document-links", as: SessionDocumentLink.self) where documentIDs.contains(link.documentID) { ids.insert(link.sessionID) }
        return try all.filter { $0.kind == .classroom && ids.contains($0.id) }.filter {
            try !transcripts(classroomID: $0.id).isEmpty || !interpretationCaptions(sessionID: $0.id).isEmpty
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func transcriptExportFiles(itemID: String, format: TranscriptExportFormat, bilingual: Bool) throws -> [String: Data] {
        try withReadSnapshot {
            let sessions = try transcriptSessions(for: itemID)
            guard !sessions.isEmpty else { throw LibraryError.message("没有已保存的关联转写，未生成空导出。") }
            var files: [String: Data] = [:]
            for session in sessions {
                let captions = try interpretationCaptions(sessionID: session.id)
                if !captions.isEmpty, format == .srt || format == .vtt {
                    let name = (try? WorkspaceCatalog.validName(session.title)) ?? "Transcript"
                    let tracks = (bilingual ? ["source", "translation"] : ["source"]).filter { track in captions.contains(where: { $0.track == track }) }
                    guard !tracks.isEmpty else { throw LibraryError.message("interpretation.noSourceCaptions") }
                    for track in tracks {
                        if let text = try interpretationExportText(sessionID: session.id, format: format, bilingual: bilingual, track: track) {
                            files[name + "-" + String(session.id.prefix(8)) + "-" + track + "." + format.rawValue] = Data(text.utf8)
                        }
                    }
                    continue
                }
                if var online = try interpretationExportText(sessionID: session.id, format: format, bilingual: bilingual) {
                    if format == .md { online = "# " + session.title + "\n\n" + online }
                    let name = (try? WorkspaceCatalog.validName(session.title)) ?? "Transcript"
                    files[name + "-" + String(session.id.prefix(8)) + "." + format.rawValue] = Data(online.utf8)
                    continue
                }
                let rows = try transcripts(classroomID: session.id)
                let translations = bilingual ? try TranscriptTextFormatter.translations(rows: rows, cloudJSON: databaseRows("SELECT json FROM records WHERE collection='cloud-state' AND owner_id=?", [session.id]).compactMap { $0["json"] }, targetLanguage: classroom(id: session.id)?.targetLanguage) : [:]
                var output = TranscriptTextFormatter.local(rows: rows, translations: translations, format: format)
                if format == .md { output = "# " + session.title + "\n\n" + output }
                let name = (try? WorkspaceCatalog.validName(session.title)) ?? "Transcript"
                files[name + "-" + String(session.id.prefix(8)) + "." + format.rawValue] = Data(output.utf8)
            }
            return files
        }
    }

    /// Independent caption tracks stay independent in exports. Display/receive
    /// timing is labeled explicitly; no source timing is copied to a translation.
    func interpretationExportText(sessionID: String, format: TranscriptExportFormat, bilingual: Bool, track: String? = nil) throws -> String? {
        let all = try interpretationCaptions(sessionID: sessionID)
        guard !all.isEmpty else { return nil }
        let rows = all.filter { (bilingual || $0.track == "source") && (track == nil || $0.track == track) }
        guard !rows.isEmpty else { throw LibraryError.message("interpretation.noSourceCaptions") }
        return try TranscriptTextFormatter.online(rows: rows, format: format)
    }
}
