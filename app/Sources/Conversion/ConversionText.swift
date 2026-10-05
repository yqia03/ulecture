import Foundation

enum ConversionText {
    static func t(_ key: String, _ language: String) -> String {
        let index = language == "zh-Hans" ? 1 : language == "zh-Hant" ? 2 : language == "ja" ? 4 : 3
        if let row = rows[key] { return row[index] }
        if let cloud = CloudFailure(rawValue: key) { return CloudViewText.failure(cloud, language) }
        return CloudViewText.t(key, language)
    }
    private static let rows: [String: [String]] = Dictionary(uniqueKeysWithValues: source.split(separator: "\n").map { String($0).components(separatedBy: "|") }.filter { $0.count == 5 }.map { ($0[0], $0) })
    private static let source = """
    fileTitle|文件翻译|檔案翻譯|Document translation|ファイル翻訳
    conversionTitle|文件转换组件|檔案轉換元件|Document conversion components|文書変換コンポーネント
    conversionHelp|PDF 与课件转换完全在本机运行。按文件清单校验随应用提供的固定组件。|PDF 與課件轉換完全在本機執行。依檔案清單校驗隨應用程式提供的固定元件。|PDF and slide conversion runs locally. Verify the fixed components against this app's file manifest.|PDF とスライドの変換はローカルで行います。同梱コンポーネントをファイル一覧と照合します。
    conversionUnchecked|尚未检查|尚未檢查|Not checked|未確認
    conversionChecking|正在校验本地组件…|正在校驗本機元件…|Verifying local components…|ローカルコンポーネントを検証中…
    conversionRepairing|正在复制并验证本地修复资源…|正在複製並驗證本機修復資源…|Copying and verifying local repair resources…|修復リソースをコピーして検証中…
    conversionReady|转换组件已校验，可供本地使用|轉換元件已校驗，可於本機使用|Conversion components verified and ready|変換コンポーネントを検証しました。利用可能です
    conversionFailedCheck|组件检查未通过|元件檢查未通過|Component verification failed|コンポーネントの検証に失敗しました
    conversionCancelled|检查或修复已取消，原有资源保留|檢查或修復已取消，原有資源保留|Check or repair cancelled; existing resources retained|検証または修復をキャンセルしました。既存リソースは保持されています
    conversionCheck|检查本地组件|檢查本機元件|Check local components|ローカルコンポーネントを確認
    conversionRepair|从完整本地应用修复…|從完整本機應用程式修復…|Repair from a complete local app…|完全なローカルアプリから修復…
    conversionRepairHelp|选择本机同一构建的完整 ULecture.app；校验通过后复制到应用支持目录。不会联网下载或更改全局安装，旧修复版本保留。|選擇本機同一建置的完整 ULecture.app；校驗通過後複製至應用程式支援目錄。不會連網下載或更改全域安裝，舊修復版本保留。|Choose a complete local ULecture.app from the same build. Verified resources are copied into Application Support. No download or global installation; previous repairs are retained.|同じビルドの完全な ULecture.app を選択してください。検証後に Application Support にコピーします。ダウンロードや全体へのインストールは行わず、以前の修復版も保持します。
    conversion.missingManifest|应用校验清单缺失或损坏，请重新安装完整应用。|應用程式校驗清單遺失或損壞，請重新安裝完整應用程式。|The app's integrity manifest is missing or damaged. Reinstall the complete app.|アプリの検証一覧がないか破損しています。完全なアプリを再インストールしてください。
    conversion.damagedResource|转换资源缺失或与当前构建不符，可使用完整本地应用修复。|轉換資源遺失或與目前建置不符，可使用完整本機應用程式修復。|A conversion resource is missing or does not match this build. Repair from a complete local app.|変換リソースが不足またはビルドと不一致です。完全なローカルアプリから修復してください。
    conversion.incompatibleSource|所选应用缺少同一构建的完整资源，现有组件未更改。|所選應用程式缺少同一建置的完整資源，現有元件未變更。|The selected app does not contain this build's complete resources. Existing components are unchanged.|選択したアプリには同一ビルドの完全なリソースがありません。既存コンポーネントは変更されていません。
    conversion.invalidPath|组件路径无效，已停止检查或修复。|元件路徑無效，已停止檢查或修復。|Invalid component path. Check or repair stopped.|コンポーネントのパスが無効です。検証または修復を停止しました。
    conversion.persistence|组件读写失败，原有资源保留；请检查磁盘权限和空间。|元件讀寫失敗，原有資源保留；請檢查磁碟權限與空間。|Component read or write failed; existing resources retained. Check disk permissions and space.|コンポーネントの読み書きに失敗しました。既存リソースは保持されています。権限と空き容量を確認してください。
    choose|选择文件|選擇檔案|Choose file|ファイルを選択
    formats|PDF、PPT、PPTX、Markdown、文本及 ULecture 笔记|PDF、PPT、PPTX、Markdown、文字與 ULecture 筆記|PDF, PPT, PPTX, Markdown, text and ULecture notes|PDF、PPT、PPTX、Markdown、テキスト、ULecture ノート
    mode|输出形式|輸出形式|Output|出力形式
    engine|文档翻译引擎|文件翻譯引擎|Document translation engine|文書翻訳エンジン
    automaticEngine|自动选择|自動選擇|Automatic|自動選択
    babelDOC|BabelDOC|BabelDOC|BabelDOC|BabelDOC
    native|内置文档翻译|內建文件翻譯|Built-in document translation|内蔵文書翻訳
    babelDOCHelp|BabelDOC 翻译并排版 PDF。自动模式下，PDF 与 PPT/PPTX 使用此引擎；使用设置中独立的文档翻译服务和 Key。|BabelDOC 翻譯並排版 PDF。自動模式下，PDF 與 PPT/PPTX 使用此引擎；使用設定中獨立的文件翻譯服務和 Key。|BabelDOC translates and typesets PDFs. Automatic mode uses it for PDF and PPT/PPTX files, with the separate document translation service and key from Settings.|BabelDOC は PDF を翻訳・組版します。自動選択では PDF と PPT/PPTX に使用され、設定の独立した文書翻訳サービスとキーを使います。
    nativeHelp|自动模式下，Markdown、文本与 ULecture 笔记使用内置引擎，可保存可编辑译文副本。也可手动选择 BabelDOC 生成 PDF。|自動模式下，Markdown、文字與 ULecture 筆記使用內建引擎，可儲存可編輯譯文副本。也可手動選擇 BabelDOC 產生 PDF。|Automatic mode uses the built-in engine for Markdown, text and ULecture notes, preserving an editable translation copy. Choose BabelDOC to produce a PDF instead.|自動選択では Markdown、テキスト、ULecture ノートに内蔵エンジンを使用し、編集可能な訳文を保存できます。BabelDOC を選択すると PDF を生成します。
    babelDOCTranslating|BabelDOC 正在翻译与排版…|BabelDOC 正在翻譯與排版…|BabelDOC is translating and typesetting…|BabelDOC で翻訳・組版中…
    babelDOCCompleted|BabelDOC 译文 PDF 已生成并通过读取检查|BabelDOC 譯文 PDF 已產生並通過讀取檢查|BabelDOC PDF generated and readability checked|BabelDOC の翻訳 PDF を生成し、読み取りを確認しました
    babelDOCCancelled|BabelDOC 已取消，源文件保留|BabelDOC 已取消，來源檔案保留|BabelDOC cancelled; source retained|BabelDOC をキャンセルしました。元ファイルは保持されています
    babelDOCInterrupted|BabelDOC 上次运行中断，可重新运行|BabelDOC 上次執行中斷，可重新執行|BabelDOC was interrupted; run it again to continue|BabelDOC が中断されました。再実行できます
    babelDOCPartial|BabelDOC 输出需要检查|BabelDOC 輸出需要檢查|Review the BabelDOC output|BabelDOC の出力を確認してください
    babelDOCRetry|重新运行 BabelDOC|重新執行 BabelDOC|Run BabelDOC again|BabelDOC を再実行
    babelDOCScannedNeedsNative|此 PDF 没有可提取的文字。请选择“内置引擎”使用本机 OCR 后重试。|此 PDF 沒有可擷取的文字。請選擇「內置引擎」使用本機 OCR 後重試。|This PDF has no extractable text. Select the built-in engine for local OCR and retry.|この PDF には抽出できるテキストがありません。「内蔵エンジン」でローカル OCR を使用して再試行してください。
    babelDOCMissing|BabelDOC 组件缺失或不可用，请安装包含 BabelDOC 组件的完整应用，或选择内置文档翻译引擎。|BabelDOC 元件遺失或無法使用，請安裝包含 BabelDOC 元件的完整應用程式，或選擇內建文件翻譯引擎。|BabelDOC components are missing or unavailable. Install the complete app with BabelDOC components, or select the built-in document translation engine.|BabelDOC コンポーネントがないか利用できません。BabelDOC を含む完全なアプリをインストールするか、内蔵文書翻訳エンジンを選択してください。
    babelDOCOutputReview|请在预览中核对译文、公式、表格与扫描内容。BabelDOC 输出 PDF；可编辑副本请使用内置引擎。|請在預覽中核對譯文、公式、表格與掃描內容。BabelDOC 輸出 PDF；可編輯副本請使用內建引擎。|Review translations, formulas, tables and scanned content in the preview. BabelDOC produces PDFs; use the built-in engine for editable copies.|プレビューで訳文、数式、表、スキャン内容を確認してください。BabelDOC は PDF を出力します。編集可能なコピーには内蔵エンジンを使用してください。
    translated|仅译文|僅譯文|Translation only|訳文のみ
    bilingual|双语对照|雙語對照|Bilingual|対訳
    preparing|正在提取和转换文件…|正在擷取及轉換檔案…|Preparing and extracting document…|文書を変換・抽出中…
    translating|正在翻译文字区域…|正在翻譯文字區域…|Translating text regions…|テキスト領域を翻訳中…
    rendering|正在排版和验证输出…|正在排版及驗證輸出…|Laying out and verifying output…|組版と出力の検証中…
    completed|所有已提取文字区域已翻译|所有已擷取文字區域已翻譯|All extracted text regions translated|抽出したテキスト領域をすべて翻訳しました
    partial|部分完成，请查看未处理区域|部分完成，請查看未處理區域|Partly complete; review uncovered regions|一部完了。未処理の領域を確認してください
    failed|任务失败，来源与已完成结果保留|任務失敗，來源與已完成結果保留|Task failed; source and completed results retained|失敗しました。元データと完了した結果は保持されています
    cancelled|已取消，完成的区域已保存|已取消，完成的區域已儲存|Cancelled; completed regions saved|キャンセルしました。完了した領域は保存されています
    interrupted|上次任务中断，可继续未完成区域|上次任務中斷，可繼續未完成區域|Interrupted; resume unfinished regions|中断しました。未完了の領域から再開できます
    incompatibleCheckpoint|此任务使用不同的处理版本，来源和已有输出保留。请重新选择来源开始新任务。|此任務使用不同的處理版本，來源和已有輸出保留。請重新選擇來源開始新任務。|This task uses a different processing version. Its source and outputs are retained. Choose the source again to start a new task.|異なる処理バージョンのタスクです。元データと出力は保持されています。元ファイルを選び直して新しいタスクを開始してください。
    interruptedUsageUnknown|上次请求中断，用量未知；已保存的区域不会重复发送。|上次請求中斷，用量未知；已儲存的區域不會重複傳送。|Previous request interrupted; usage unknown. Saved regions will not be resent.|前回のリクエストは中断され、使用量は不明です。保存済みの領域は再送しません。
    history|文件任务|檔案任務|Document tasks|ファイルタスク
    download|下载至 Downloads|下載至 Downloads|Save to Downloads|Downloads に保存
    saveAs|另存为…|另存為…|Save as…|名前を付けて保存…
    companion|保存可编辑副本…|儲存可編輯副本…|Save editable copy…|編集可能なコピーを保存…
    coverage|覆盖与版面说明|涵蓋範圍與版面說明|Coverage and layout|処理範囲とレイアウト
    savedAt|已保存至|已儲存至|Saved to|保存先
    regions|文字区域|文字區域|text regions|テキスト領域
    page|源页|來源頁|Source page|元のページ
    outputPages|输出页|輸出頁|Output pages|出力ページ
    empty|选择文件并开始翻译。结果生成并验证后会在此预览。|選擇檔案並開始翻譯。結果產生及驗證後會在此預覽。|Choose a file and translate. The verified output will appear here.|ファイルを選択して翻訳してください。検証済みの出力がここに表示されます。
    resourcesMissing|文件转换组件缺失或损坏，请在首次准备中检查并从完整本地应用修复。|檔案轉換元件遺失或損壞，請在首次準備中檢查並從完整本機應用程式修復。|Conversion components are missing or damaged. Open First Setup to check and repair from a complete local app.|変換コンポーネントがないか破損しています。初期設定から確認し、完全なローカルアプリを使って修復してください。
    unsupported|不支持此文件类型，原件保留。|不支援此檔案類型，原件保留。|Unsupported file type. Original retained.|非対応のファイル形式です。元ファイルは保持されています。
    invalidDocument|文件内容无效或无法读取，原件保留。|檔案內容無效或無法讀取，原件保留。|Invalid or unreadable file. Original retained.|ファイルが無効または読み取れません。元ファイルは保持されています。
    encrypted|文件已加密，请先提供可读取的副本。|檔案已加密，請先提供可讀取的副本。|Encrypted file. Use an unlocked copy.|暗号化されています。解除済みのコピーを使用してください。
    tooLarge|文件、页数或文字区域超过处理上限。|檔案、頁數或文字區域超過處理上限。|File, page count or text region exceeds processing limits.|ファイル・ページ数・文字領域が処理上限を超えています。
    conversionFailed|本地转换失败，原件保留，可重试。|本機轉換失敗，原件保留，可重試。|Local conversion failed. Original retained; retry is available.|ローカル変換に失敗しました。元ファイルは保持され、再試行できます。
    timedOut|本地转换超时，转换进程已停止。|本機轉換逾時，轉換程序已停止。|Local conversion timed out and was stopped.|変換がタイムアウトしたため、プロセスを停止しました。
    noText|未找到可可靠翻译的文字；未生成空白译文冒充完成。|找不到可可靠翻譯的文字；未產生空白譯文冒充完成。|No reliably translatable text found. No completed translation was generated.|確実に翻訳できるテキストがありません。完了した訳文は生成されていません。
    persistence|保存失败，任务与结果草稿保留。|儲存失敗，任務與結果草稿保留。|Save failed; task and result drafts retained.|保存に失敗しました。タスクと結果の下書きは保持されています。
    invalidOutput|输出未通过可读性检查，未标记完成。|輸出未通過可讀性檢查，未標記完成。|Output failed readability validation; not marked complete.|出力の読み取り検証に失敗したため、完了として扱いません。
    staticSlides|幻灯片输出为静态页面；动画、转场和嵌入媒体不播放。|投影片輸出為靜態頁面；動畫、轉場及內嵌媒體不播放。|Slides are static pages; animations, transitions and embedded media do not play.|スライドは静止ページです。アニメーション・切り替え効果・埋め込みメディアは再生しません。
    speakerNotesExcluded|演讲者备注未包含在正文或翻译中。|演講者備註未包含於正文或翻譯。|Speaker notes are not included in slide text or translation.|発表者ノートは本文や翻訳に含まれていません。
    fontSubstitutionNeedsReview|转换可能替换缺失字体；请核对换行、符号与分页。|轉換可能替換遺失字型；請核對換行、符號與分頁。|Missing fonts may be substituted. Review line breaks, symbols and pagination.|不足するフォントが置換される場合があります。改行・記号・改ページを確認してください。
    graphicsRasterized300DPI|部分页面的图形以 300 dpi 图像保留视觉效果；译文文字可搜索，原件仍保留。|部分頁面圖形以 300 dpi 影像保留視覺效果；譯文文字可搜尋，原件仍保留。|Some page graphics are preserved as 300 dpi images. Translation text is searchable; originals remain intact.|一部ページの図形は 300 dpi 画像で外観を保持します。訳文は検索でき、元ファイルも保持されます。
    nestedFormSerialization|嵌套图形保存后无法可靠移除文字，因此采用图形图像。|巢狀圖形儲存後無法可靠移除文字，因此採用圖形影像。|Nested graphics could not retain text removal after saving; a graphics image is used.|入れ子図形の保存後に文字除去を維持できないため、図形画像を使用します。
    graphicsSerializationChanged|图形保存后的色彩或剪裁发生变化，因此采用图形图像。|圖形儲存後的色彩或裁切改變，因此採用圖形影像。|Saved graphics changed color or clipping; a graphics image is used.|保存後の色やクリッピングが変化したため、図形画像を使用します。
    missingFont|缺失的请求字体|遺失的指定字型|Unavailable requested font|指定フォントがありません
    renderedFonts|这些页实际使用的字体|這些頁實際使用的字型|Fonts observed on these rendered pages|変換後ページで検出したフォント
    speakerNotes|演讲者备注（未纳入翻译）|演講者備註（未納入翻譯）|Speaker notes (excluded from translation)|発表者ノート（翻訳対象外）
    notesMappingUnavailable|部分备注未能可靠关联至源页。|部分備註無法可靠關聯來源頁。|Some notes could not be reliably mapped to source pages.|一部のノートを元のページに正確に対応付けできませんでした。
    legacyMetadataConverted|旧版 PPT 的备注与字体信息经本地格式转换提取，请核对。|舊版 PPT 的備註與字型資訊經本機格式轉換擷取，請核對。|Legacy PPT notes and font information were extracted through local format conversion; review them.|旧形式 PPT のノートとフォント情報はローカル変換で抽出しています。内容を確認してください。
    tableRowContinued|过高的表格行按行号与列号展开至续页，内容保持完整。|過高的表格行依行號與欄號展開至續頁，內容保持完整。|Tall table rows continue by row and column number to preserve readable content.|高さが大きい表の行は、行番号と列番号で続きのページに展開しています。
    animationsDetected|检测到动画或转场；输出仅包含静态内容。|偵測到動畫或轉場；輸出僅包含靜態內容。|Animations or transitions detected; output contains static content only.|アニメーションまたは切り替え効果を検出しました。出力は静止内容のみです。
    embeddedMediaDetected|检测到内嵌音视频；输出不含播放能力。|偵測到內嵌影音；輸出不含播放功能。|Embedded media detected; output has no playback.|埋め込みメディアを検出しました。出力には再生機能がありません。
    noExtractableText|此页没有可提取的文字，未计为已翻译。|此頁沒有可擷取的文字，未計為已翻譯。|No text extracted on this page; not counted as translated.|このページに抽出可能な文字はなく、翻訳済みには数えません。
    formulasPreserved|公式区域保留原样。|公式區域保持原樣。|Formula regions preserved unchanged.|数式領域は元のまま保持しています。
    localOCR|此页包含本机 OCR 识别的文字，请核对识别结果。|此頁包含本機 OCR 辨識文字，請核對辨識結果。|This page includes local OCR text. Review recognition accuracy.|このページには端末内 OCR の文字が含まれます。認識結果を確認してください。
    ocrLowConfidence|存在低置信度 OCR 区域，未可靠翻译。|有低可信度 OCR 區域，未可靠翻譯。|Low-confidence OCR regions remain untranslated.|信頼度の低い OCR 領域は未翻訳です。
    complexImageTextUntranslated|复杂背景内文字无法可靠移除，保留并列为未处理区域。|複雜背景內文字無法可靠移除，保留並列為未處理區域。|Text on complex image backgrounds could not be reliably removed and remains uncovered.|複雑な画像背景の文字を確実に除去できず、未処理として保持しています。
    ocrLanguageUnavailable|本机 OCR 不支持所选语言。|本機 OCR 不支援所選語言。|Local OCR does not support this language.|端末内 OCR はこの言語に対応していません。
    imagesNotAnalyzed|图片保留；未对图片含义作语义分析。|圖片保留；未對圖片含義進行語意分析。|Images preserved; their meaning was not analyzed.|画像は保持されていますが、意味の解析は行っていません。
    missingImage|本地图片缺失，原引用保留。|本機圖片遺失，原引用保留。|Local image missing; original reference retained.|ローカル画像がありません。元の参照は保持されています。
    remoteImageNotFetched|未自动获取远程或外部图片。|未自動取得遠端或外部圖片。|Remote or external images were not fetched automatically.|リモートや外部の画像は自動取得していません。
    """
}
