import Foundation

enum TranslationDomain: String, Codable, CaseIterable, Identifiable {
    case general, marketing, ai, programming, film, food
    var id: String { rawValue }
    var instruction: String {
        switch self {
        case .general: return "Use clear natural language."
        case .marketing: return "Use marketing terminology without inventing persuasive claims."
        case .ai: return "Use terminology customary in artificial intelligence and machine learning."
        case .programming: return "Use software engineering terminology. Preserve code, symbols, API identifiers and URLs exactly."
        case .film: return "Use terminology customary in film and television; preserve proper names."
        case .food: return "Use culinary terminology; preserve quantities, units and allergens."
        }
    }
}

struct TranslationTerm: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var sourceLanguage: String = "en"
    var source: String
    var targetLanguage: String = "zh-Hans"
    var translation: String
    var note: String = ""
    var enabled: Bool = true
    var scopeID: String = "text"
    var conflictKey: String { [scopeID, sourceLanguage, targetLanguage, source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "\u{1f}") }
    func validated() throws -> TranslationTerm {
        var value = self
        value.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        value.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, ["en", "ja"].contains(sourceLanguage), ["zh-Hans", "zh-Hant"].contains(targetLanguage),
              !value.source.isEmpty, !value.translation.isEmpty, !scopeID.isEmpty,
              value.source.count <= 500, value.translation.count <= 2000, note.count <= 4000 else { throw CloudFailure.invalidConfiguration }
        return value
    }
}

struct TranslationGlossary: Codable, Equatable {
    var schema = 1
    var revision = 1
    var terms: [TranslationTerm] = []
    func snapshot(scopeID: String, source: String, target: String) -> [TranslationTerm] {
        terms.filter { $0.enabled && $0.scopeID == scopeID && $0.sourceLanguage == source && $0.targetLanguage == target }
    }
}
struct TranslationTermConflict: Error { let existing: TranslationTerm; let incoming: TranslationTerm }
enum TermImportPolicy { case rejectConflicts, keepExisting, replaceExisting }

enum TranslationTermFile {
    static let columns = ["sourceLanguage", "source", "targetLanguage", "translation", "note", "enabled", "scopeID"]
    static func encode(_ terms: [TranslationTerm], csv: Bool) throws -> Data {
        if !csv { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(terms) }
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = [columns] + terms.map { [$0.sourceLanguage, $0.source, $0.targetLanguage, $0.translation, $0.note, $0.enabled ? "true" : "false", $0.scopeID] }
        return Data((rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
    }
    static func decode(_ data: Data, csv: Bool, scopeID: String) throws -> [TranslationTerm] {
        guard data.count <= 2_000_000 else { throw CloudFailure.responseTooLarge }
        let terms: [TranslationTerm]
        if !csv { terms = try JSONDecoder().decode([TranslationTerm].self, from: data) }
        else {
            guard let source = String(data: data, encoding: .utf8) else { throw CloudFailure.invalidConfiguration }
            let rows = try parseCSV(source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source)
            guard rows.first == columns else { throw CloudFailure.invalidConfiguration }
            terms = try rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { row in
                guard row.count == columns.count, ["true", "false"].contains(row[5]) else { throw CloudFailure.invalidConfiguration }
                return TranslationTerm(sourceLanguage: row[0], source: row[1], targetLanguage: row[2], translation: row[3], note: row[4], enabled: row[5] == "true", scopeID: scopeID)
            }
        }
        guard terms.count <= 5000 else { throw CloudFailure.responseTooLarge }
        // Import is explicitly into the currently displayed scope. A file cannot
        // silently replace terminology belonging to another course.
        return try terms.map { term in var copy = term; copy.id = UUID().uuidString; copy.scopeID = scopeID; return try copy.validated() }
    }
    private static func parseCSV(_ source: String) throws -> [[String]] {
        let chars = Array(source); var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," { row.append(field); field = ""; closed = false }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""; closed = false
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else if c == "\"", field.isEmpty, !closed { quoted = true }
            else { guard !closed, c != "\"" else { throw CloudFailure.invalidConfiguration }; field.append(c) }
            i += 1
        }
        guard !quoted else { throw CloudFailure.invalidConfiguration }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
}
