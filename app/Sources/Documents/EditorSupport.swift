import SwiftUI
import AppKit

@MainActor protocol DocumentEditingSession: AnyObject { func flush() async -> Bool }

struct PDFNavigationRequest: Equatable {
    var id = UUID()
    var documentID: String
    var sourceHash: String?
    var page: Int
    var annotationID: String? = nil
    var annotationRevision: Int? = nil
}
struct BlockNavigationRequest: Equatable { var id = UUID(); var blockID: String; var revision: Int? }
@MainActor final class DocumentNavigationState: ObservableObject {
    static let shared = DocumentNavigationState()
    @Published var currentHashes: [String: String] = [:]
    @Published var requests: [String: PDFNavigationRequest] = [:]
    @Published var blockRequests: [String: BlockNavigationRequest] = [:]
    func request(documentID: String, sourceHash: String?, page: Int) {
        requests[documentID] = PDFNavigationRequest(documentID: documentID, sourceHash: sourceHash, page: page)
    }
    func requestBlock(documentID: String, blockID: String, revision: Int? = nil) { blockRequests[documentID] = BlockNavigationRequest(blockID: blockID, revision: revision) }
    func requestAnnotation(documentID: String, sourceHash: String, page: Int, annotationID: String, revision: Int) {
        requests[documentID] = PDFNavigationRequest(documentID: documentID, sourceHash: sourceHash, page: page, annotationID: annotationID, annotationRevision: revision)
    }
}

@MainActor enum DocumentEditingSessions {
    private final class WeakSession { weak var value: (any DocumentEditingSession)?; init(_ value: any DocumentEditingSession) { self.value = value } }
    private static var sessions: [ObjectIdentifier: WeakSession] = [:]
    static func register(_ session: any DocumentEditingSession) { sessions[ObjectIdentifier(session)] = WeakSession(session) }
    static func noteEditor(at url: URL) -> BlockNoteEditorModel? {
        sessions.values.compactMap { $0.value as? BlockNoteEditorModel }.first { $0.store.packageURL.standardizedFileURL == url.standardizedFileURL }
    }
    static func flushAll() async -> Bool {
        sessions = sessions.filter { $0.value.value != nil }
        var successful = true
        for entry in sessions.values { if let session = entry.value, !(await session.flush()) { successful = false } }
        return successful
    }
}

enum EditorText {
    static let rows: [String: [String]] = [
        "saved": ["已保存", "已儲存", "Saved", "保存済み"],
        "assistant": ["AI 助手", "AI 助理", "AI assistant", "AI アシスタント"],
        "document": ["文档", "文件", "Document", "ドキュメント"],
        "conflict": ["文件已在其他位置修改。请重新打开磁盘版本或另存副本。", "檔案已在其他位置修改。請重新開啟磁碟版本或另存副本。", "The file changed outside this editor. Reload the disk version or save a copy.", "ファイルが別の場所で変更されました。ディスクの版を開くか、コピーを保存してください。"],
        "invalidDocument": ["文档损坏或格式不受支持，原件保持不变。", "文件損毀或格式不受支援，原件保持不變。", "The document is damaged or unsupported. The original is unchanged.", "ファイルが破損しているか未対応の形式です。元のファイルは変更されていません。"],
        "readOnlyError": ["文档或所在文件夹不可写，请另存副本。", "文件或所在資料夾無法寫入，請另存副本。", "The document or folder is read-only. Save a separate copy.", "ファイルまたはフォルダに書き込めません。コピーを保存してください。"],
        "missingResource": ["文档资源缺失：", "文件資源遺失：", "A document resource is missing: ", "ドキュメントのリソースがありません："],
        "noteRevision": ["笔记版本", "筆記版本", "Note revision", "ノートの版"],
        "annotationRevision": ["批注版本", "註解版本", "Annotation revision", "注釈の版"],
        "sourceRevision": ["PDF 源版本", "PDF 來源版本", "PDF source version", "PDF 元ファイルの版"],
        "annotation": ["批注", "註解", "Annotation", "注釈"],
        "folderUnavailable": ["文档文件夹不可用。", "文件資料夾無法使用。", "The document folder is unavailable.", "ドキュメントのフォルダを利用できません。"],
        "folderSyncFailed": ["无法同步文档文件夹，保存未完成。", "無法同步文件資料夾，儲存尚未完成。", "The document folder could not be synchronized.", "ドキュメントのフォルダを同期できませんでした。"],
        "textEncoding": ["当前文字无法按原编码保存，请另存 UTF-8 副本以保留所有字符。", "目前文字無法以原編碼儲存，請另存 UTF-8 副本以保留所有字元。", "This text cannot be saved in its original encoding. Save a UTF-8 copy to preserve every character.", "元の文字コードでは保存できません。すべての文字を保持するには UTF-8 のコピーを保存してください。"],
        "markdownEncoding": ["Markdown 必须使用 UTF-8；原文件字节保持不变。", "Markdown 必須使用 UTF-8；原始檔案位元組保持不變。", "Markdown must be UTF-8; the original bytes have not been changed.", "Markdown は UTF-8 である必要があります。元のファイルは変更されていません。"],
        "textDoesNotFit": ["文字无法排入导出页面。", "文字無法排入匯出頁面。", "Text could not fit on an output page.", "文字を出力ページに配置できませんでした。"],
        "annotationTooLarge": ["批注大于目标页面，请先缩小后再复制。", "註解大於目標頁面，請先縮小後再複製。", "The annotation is larger than the target page. Resize it before copying.", "注釈が移動先のページより大きいため、縮小してからコピーしてください。"],
        "saving": ["正在保存…", "正在儲存…", "Saving…", "保存中…"],
        "saveFailed": ["保存失败，修改仍在编辑器中", "儲存失敗，修改仍在編輯器中", "Save failed; changes remain in the editor", "保存失敗・変更はエディタに保持されています"],
        "loading": ["正在打开…", "正在開啟…", "Opening…", "読み込み中…"],
        "retry": ["重试保存", "重試儲存", "Retry save", "保存を再試行"],
        "reload": ["重新打开磁盘版本", "重新開啟磁碟版本", "Reload disk version", "ディスクの版を開く"],
        "copy": ["复制", "複製", "Copy", "コピー"],
        "export": ["导出", "匯出", "Export", "書き出す"],
        "saveCopy": ["另存副本", "另存副本", "Save a copy", "コピーを保存"],
        "undo": ["撤销", "復原", "Undo", "取り消す"],
        "redo": ["重做", "重做", "Redo", "やり直す"],
        "delete": ["删除", "刪除", "Delete", "削除"],
        "select": ["选择与移动", "選取與移動", "Select and move", "選択・移動"],
        "read": ["阅读与选择文字", "閱讀與選取文字", "Read and select text", "閲覧・テキスト選択"],
        "highlight": ["高亮", "醒目提示", "Highlight", "ハイライト"],
        "underline": ["下划线", "底線", "Underline", "下線"],
        "strikeOut": ["删除线", "刪除線", "Strikethrough", "取り消し線"],
        "ink": ["画笔", "畫筆", "Pen", "ペン"],
        "eraser": ["橡皮擦", "橡皮擦", "Eraser", "消しゴム"],
        "freeText": ["文本框", "文字方塊", "Text box", "テキストボックス"],
        "stickyNote": ["便签", "便條", "Sticky note", "付箋"],
        "rectangle": ["矩形", "矩形", "Rectangle", "四角形"],
        "ellipse": ["椭圆", "橢圓", "Ellipse", "楕円"],
        "arrow": ["箭头", "箭頭", "Arrow", "矢印"],
        "color": ["颜色", "顏色", "Color", "色"],
        "width": ["粗细", "粗細", "Stroke width", "線の太さ"],
        "text": ["文字", "文字", "Text", "文字"],
        "page": ["页", "頁", "Page", "ページ"],
        "fit": ["适合宽度", "符合寬度", "Fit width", "幅に合わせる"],
        "rotate": ["旋转视图", "旋轉檢視", "Rotate view", "表示を回転"],
        "annotatedPDF": ["带标注 PDF", "含註解 PDF", "Annotated PDF", "注釈付き PDF"],
        "flattenedPDF": ["扁平化 PDF", "平面化 PDF", "Flattened PDF", "注釈を統合した PDF"],
        "oldVersion": ["旧版本批注", "舊版本註解", "Annotations on earlier versions", "以前の版の注釈"],
        "currentVersion": ["当前源文件", "目前來源檔案", "Current source file", "現在の元ファイル"],
        "noteHistory": ["正在查看历史笔记版本，只读", "正在檢視歷史筆記版本，唯讀", "Viewing a historical note revision, read-only", "以前のノート版を表示中・読み取り専用"],
        "annotationHistory": ["正在查看引用的批注版本，只读", "正在檢視引用的批註版本，唯讀", "Viewing the referenced annotation revision, read-only", "参照された注釈の版を表示中・読み取り専用"],
        "versionWarning": ["源文件已更改。旧批注只在对应旧版显示，未套用到新页。", "來源檔案已變更。舊註解只在對應舊版顯示，未套用至新頁。", "The source changed. Earlier annotations remain on their original version, not the new pages.", "元ファイルが変わりました。以前の注釈は元の版に保持されています。"],
        "reassociate": ["将选中批注复制到当前文件的指定页", "將選取註解複製至目前檔案的指定頁", "Copy selected annotation to a page of the current file", "選択した注釈を現在のファイルの指定ページにコピー"],
        "recovered": ["已找回未保存草稿，请核对后保存。", "已找回未儲存下書，請核對後儲存。", "An unsaved draft was recovered. Review it before saving.", "未保存の下書きを復元しました。確認して保存してください。"],
        "addBlock": ["添加块", "新增區塊", "Add block", "ブロックを追加"],
        "heading": ["标题", "標題", "Heading", "見出し"],
        "paragraph": ["段落", "段落", "Paragraph", "段落"],
        "list": ["列表", "清單", "List", "リスト"],
        "todo": ["待办", "待辦", "To-do", "チェックリスト"],
        "image": ["图片", "圖片", "Image", "画像"],
        "table": ["表格", "表格", "Table", "表"],
        "quote": ["引用", "引用", "Quote", "引用"],
        "code": ["代码", "程式碼", "Code", "コード"],
        "codeLanguage": ["代码语言", "程式碼語言", "Code language", "コードの言語"],
        "indent": ["增加缩进", "增加縮排", "Indent", "インデントを増やす"],
        "outdent": ["减少缩进", "減少縮排", "Outdent", "インデントを減らす"],
        "ordered": ["编号列表", "編號清單", "Numbered list", "番号付きリスト"],
        "unordered": ["项目列表", "項目清單", "Bullet list", "箇条書き"],
        "rawMarkdown": ["保留的 Markdown", "保留的 Markdown", "Preserved Markdown", "保持された Markdown"],
        "moveUp": ["上移", "上移", "Move up", "上へ"],
        "moveBlock": ["拖动以移动块", "拖曳以移動區塊", "Drag to move block", "ドラッグして移動"],
        "moveDown": ["下移", "下移", "Move down", "下へ"],
        "duplicate": ["复制块", "複製區塊", "Duplicate block", "ブロックを複製"],
        "addRow": ["添加行", "新增列", "Add row", "行を追加"],
        "addColumn": ["添加列", "新增欄", "Add column", "列を追加"],
        "removeRow": ["删除末行", "刪除末列", "Remove last row", "最後の行を削除"],
        "removeColumn": ["删除末列", "刪除末欄", "Remove last column", "最後の列を削除"],
        "pageLink": ["引用当前课件页", "引用目前教材頁", "Link current course page", "現在の教材ページを参照"],
        "choosePageDocument": ["选择要引用的课件", "選擇要引用的教材", "Choose a document to link", "参照する教材を選択"],
        "missingImage": ["图片缺失；原引用已保留", "圖片遺失；原引用已保留", "Image missing; reference preserved", "画像がありません・参照は保持されています"],
        "bold": ["加粗", "粗體", "Bold", "太字"],
        "italic": ["斜体", "斜體", "Italic", "斜体"],
        "source": ["源码", "原始碼", "Source", "ソース"],
        "preview": ["预览", "預覽", "Preview", "プレビュー"],
        "convertBlocks": ["另存为块笔记", "另存為區塊筆記", "Save as block note", "ブロックノートとして保存"],
        "fontSize": ["字号", "字級", "Font size", "文字サイズ"],
        "annotationText": ["输入批注文字", "輸入註解文字", "Annotation text", "注釈の文字"],
        "done": ["完成", "完成", "Done", "完了"]
    ]
    static func get(_ key: String, _ language: String) -> String {
        let index = language == "zh-Hans" ? 0 : language == "zh-Hant" ? 1 : language == "ja" ? 3 : 2
        return rows[key]?[index] ?? key
    }
    static func failure(_ detail: String, _ language: String) -> String {
        if detail == DocumentFailure.conflict.localizedDescription { return get("conflict", language) }
        if detail == DocumentFailure.invalidFormat.localizedDescription { return get("invalidDocument", language) }
        if detail.contains("read-only") || detail.contains("not writable") { return get("readOnlyError", language) }
        let messages = ["The note could not be saved.": "saveFailed", "The document folder is unavailable.": "folderUnavailable", "The document folder could not be synchronized.": "folderSyncFailed", "This text cannot be saved in its original encoding. Save a UTF-8 copy to preserve every character.": "textEncoding", "Markdown must be UTF-8; the original bytes have not been changed.": "markdownEncoding", "Text could not fit on an output page.": "textDoesNotFit", "The annotation is larger than the target page. Resize it before copying.": "annotationTooLarge"]
        if let key = messages[detail] { return get(key, language) }
        let prefix = "A document resource is missing: "
        if detail.hasPrefix(prefix) {
            var resource = String(detail.dropFirst(prefix.count))
            for (source, key) in [("Note revision", "noteRevision"), ("Annotation revision", "annotationRevision"), ("PDF source version", "sourceRevision"), ("Annotation", "annotation")] where resource.hasPrefix(source + " ") {
                resource = get(key, language) + String(resource.dropFirst(source.count)); break
            }
            return get("missingResource", language) + resource
        }
        return detail
    }
}

struct EditorStatusBar: View {
    let state: String
    let error: String?
    let language: String
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state == "saveFailed" ? "exclamationmark.circle" : "checkmark.circle")
            Text(EditorText.get(state, language)).font(.caption)
            if let error { Text(EditorText.failure(error, language)).font(.caption).lineLimit(2).help(EditorText.failure(error, language)) }
            Spacer(minLength: 2)
            if state == "saveFailed" { Button(EditorText.get("retry", language), action: retry).controlSize(.small) }
        }.foregroundStyle(state == "saveFailed" ? Color.red : Color.secondary).padding(.horizontal, 12).padding(.vertical, 7)
    }
}
