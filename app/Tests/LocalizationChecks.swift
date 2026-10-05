import Foundation

@main enum LocalizationChecks {
    @MainActor static func main() throws {
        var checks: [String] = []
        func check(_ label: String, _ condition: Bool) throws {
            guard condition else { throw NSError(domain: "LocalizationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        let languages = ["zh-Hans","zh-Hant","en","ja"]
        let cloudPermissionMessages = [
            "zh-Hans": "服务拒绝访问，请核对权限及地区资格",
            "zh-Hant": "服務拒絕存取，請核對權限及地區資格",
            "en": "Access denied; check permissions and regional eligibility",
            "ja": "アクセスが拒否されました。権限と対象地域を確認してください"
        ]
        let sourceRows = Localizer.rows.split(separator: "\n").map { $0.split(separator: "|", omittingEmptySubsequences: false) }
        try check("every UI catalog row has key plus four nonempty languages", sourceRows.allSatisfy { $0.count == 5 && $0.allSatisfy { !$0.isEmpty } })
        try check("UI catalog keys unique", Set(sourceRows.map { $0[0] }).count == sourceRows.count)
        try check("every diagnostic template has four nonempty translations", StatusLocalizer.templates.allSatisfy { $0.translations.count == 4 && $0.translations.allSatisfy { !$0.isEmpty } })
        try check("diagnostic templates unique", Set(StatusLocalizer.templates.map(\.source)).count == StatusLocalizer.templates.count)
        for template in StatusLocalizer.templates {
            try check("dynamic placeholder parity: " + template.source, template.translations.allSatisfy { $0.contains("{0}") == template.source.contains("{0}") })
        }
        for language in languages {
            let permissionError = StatusLocalizer.cloudStatus("permission", language: language)
            try check("cloud access-denied error is distinct from the permission-settings label: " + language,
                      permissionError == cloudPermissionMessages[language] && permissionError != Localizer.string("permission", language: language))
            try check("all UI keys render: " + language, Localizer.table.keys.allSatisfy { !Localizer.string($0, language: language).isEmpty })
            try check("all status codes resolve: " + language, StatusLocalizer.codeKeys.allSatisfy { Localizer.table[$0.value] != nil && !StatusLocalizer.cloudStatus($0.key, language: language).isEmpty && ($0.key.contains(" ") || StatusLocalizer.cloudStatus($0.key, language: language) != $0.key) })
            let file = "Mixed_日本語_文件 42.bin"
            let output = StatusLocalizer.detail("正在下载 " + file, language: language)
            try check("dynamic filename preserved: " + language, output.contains(file) && !output.contains("{0}"))
            try check("dynamic SQLite code preserved: " + language, StatusLocalizer.detail("资料库操作失败（SQLite 13）。", language: language).contains("13"))
            let count = StatusLocalizer.detail("发现 3 个未完成导入文件，未计为已保存；保留在 staging 供诊断。", language: language)
            try check("recovery file count preserved: " + language, count.contains("3") && count.contains("staging"))
            let nested = StatusLocalizer.detail("录音写入失败：磁盘空间不足；内容尚未保存。", language: language)
            try check("nested failure translated: " + language, language == "zh-Hans" || !nested.contains("磁盘空间不足"))
        }
        try check("unknown filesystem path not translated", StatusLocalizer.detail("/Users/test/我的资料/lecture.pdf", language: "en") == "/Users/test/我的资料/lecture.pdf")
        try check("unknown system diagnostic retained", StatusLocalizer.detail("NSCocoaErrorDomain Code=640", language: "ja") == "NSCocoaErrorDomain Code=640")
        try check("system language resolution prioritizes supported languages", AppPreferences.resolve(["fr-FR","ja-JP","en-US"]) == "ja" && AppPreferences.resolve(["zh-HK"]) == "zh-Hant" && AppPreferences.resolve(["de-DE"]) == "en")

        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let modules = ["Audio", "Cloud", "Library"]
        let literalPattern = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        let han = try NSRegularExpression(pattern: "[\\u3400-\\u9fff]")
        var coverage: Set<String> = []
        var uncovered: Set<String> = []
        for module in modules {
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("app/Sources/" + module), includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            for file in files {
                let contents = try String(contentsOf: file, encoding: .utf8)
                for line in contents.components(separatedBy: "\n") {
                    let isDiagnostic = module == "Audio" || (module == "Cloud" && (line.contains("return \"") || line.contains("status = \""))) ||
                        (module == "Library" && (line.contains("LibraryError.message(") || line.contains("recoveryWarnings.append(") || line.contains("detail = \"")))
                    guard isDiagnostic else { continue }
                    for match in literalPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                        guard let range = Range(match.range, in: line) else { continue }
                        let literal = String(line[range].dropFirst().dropLast())
                        guard han.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil else { continue }
                        let normalized = interpolation.stringByReplacingMatches(in: literal, range: NSRange(literal.startIndex..., in: literal), withTemplate: "{0}")
                        if StatusLocalizer.templates.contains(where: { $0.source == normalized }) { coverage.insert(normalized) }
                        else { uncovered.insert(normalized) }
                    }
                }
            }
        }
        if !uncovered.isEmpty { FileHandle.standardError.write(Data(("Uncovered: " + uncovered.sorted().joined(separator: "\n") + "\n").utf8)) }
        try check("all app-owned Audio/Cloud/Library human diagnostics have four-language templates", uncovered.isEmpty)
        let output: [String:Any] = ["suite":"LocalizationChecks", "passed":checks.count, "uiKeys":Localizer.table.count, "diagnosticTemplates":StatusLocalizer.templates.count,
            "machineCodes":StatusLocalizer.codeKeys.count, "sourceDiagnosticsCovered":coverage.count, "uncovered":Array(uncovered).sorted(), "languages":languages,
            "checks":checks, "scope":"Catalog integrity and source coverage; independent of OS-generated messages and user-owned text. This is not visual/truncation acceptance."]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
