import Foundation
import SwiftUI

@MainActor final class AppPreferences: ObservableObject {
    static let shared: AppPreferences = {
        let arguments = CommandLine.arguments
        guard arguments.contains("--ui-test-library") || arguments.contains("--ui-test-workspace") else { return AppPreferences(defaults: .standard) }
        let index = arguments.firstIndex(of: "--ui-test-preferences")
        let suite = index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "local.uway.classroom.internal.uitest"
        return AppPreferences(defaults: UserDefaults(suiteName: suite)!)
    }()
    let defaults: UserDefaults
    @Published var language: String { didSet { defaults.set(language, forKey: "interfaceLanguage") } }
    @Published var dark: Bool { didSet { defaults.set(dark, forKey: "darkAppearance") } }
    @Published var hideSetup: Bool { didSet { defaults.set(hideSetup, forKey: "hideSetup") } }
    @Published var panel: String { didSet { defaults.set(panel, forKey: "classPanel") } }
    @Published var captionSize: Double { didSet { defaults.set(captionSize, forKey: "captionSize") } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: "interfaceLanguage") ?? "system"
        dark = defaults.bool(forKey: "darkAppearance")
        hideSetup = defaults.bool(forKey: "hideSetup")
        panel = defaults.string(forKey: "classPanel") ?? "notes"
        captionSize = defaults.object(forKey: "captionSize") as? Double ?? 17
    }
    var resolvedLanguage: String { Self.resolve(language == "system" ? Locale.preferredLanguages : [language]) }
    static func resolve(_ languages: [String]) -> String {
        for language in languages {
            let v = language.lowercased()
            if v.hasPrefix("zh") { return v.contains("hant") || v.contains("tw") || v.contains("hk") || v.contains("mo") ? "zh-Hant" : "zh-Hans" }
            if v.hasPrefix("ja") { return "ja" }
            if v.hasPrefix("en") { return "en" }
        }
        return "en"
    }
    func t(_ key: String) -> String { Localizer.string(key, language: resolvedLanguage) }
}

enum Localizer {
    static let rows = """
    interpretation.serviceBusy|已有同传连接或连接测试正在运行，请先暂停或等待完成。|已有同傳連線或連線測試正在執行，請先暫停或等待完成。|An interpretation connection or test is already running. Pause it or wait for completion.|通訳接続または接続テストが実行中です。一時停止するか、完了を待ってください。
    interpretation.invalidConfiguration|同传配置无效，请检查模型 ID。|同傳設定無效，請檢查模型 ID。|Invalid interpretation settings; check the model ID.|通訳設定が無効です。モデル ID を確認してください。
    interpretation.incompatibleModel|该模型不兼容专用语音翻译协议。|此模型不相容專用語音翻譯協定。|This model is incompatible with the dedicated translation protocol.|このモデルは専用音声翻訳プロトコルに対応していません。
    interpretation.unsupportedLanguage|该服务不支持所选目标语言代码。|此服務不支援所選目標語言代碼。|The target language code is unsupported by this service.|このサービスでは翻訳先言語コードがサポートされていません。
    interpretation.missingCredential|请在同声传译服务设置中配置 Key。|請在同聲傳譯服務設定中設定 Key。|Configure a key in interpretation service settings.|同時通訳サービス設定でキーを設定してください。
    interpretation.authentication|同传鉴权失败，请检查 Key 与账户权限。|同傳驗證失敗，請檢查 Key 與帳戶權限。|Interpretation authentication failed; check the key and account access.|通訳の認証に失敗しました。キーとアカウント権限を確認してください。
    interpretation.modelUnavailable|同传模型不可用或当前账户无权限。|同傳模型不可用或目前帳戶無權限。|The interpretation model is unavailable or not enabled for this account.|通訳モデルを利用できないか、アカウントに権限がありません。
    interpretation.rateLimited|同传服务达到速率或额度限制。|同傳服務達到速率或額度限制。|Interpretation rate or quota limit reached.|通訳サービスのレートまたは利用枠の上限に達しました。
    interpretation.handshakeTimeout|同传握手超时，请检查网络。|同傳交握逾時，請檢查網路。|Interpretation handshake timed out; check the network.|通訳の接続確認がタイムアウトしました。ネットワークを確認してください。
    interpretation.finishTimeout|未在时限内收到服务关闭确认。|未在時限內收到服務關閉確認。|The service did not confirm closure before the timeout.|制限時間内にサービスから終了確認が届きませんでした。
    interpretation.connectionLost|同传连接已中断。|同傳連線已中斷。|Interpretation connection was lost.|通訳の接続が切断されました。
    interpretation.protocolViolation|同传协议响应不兼容，已停止连接。|同傳協定回應不相容，已停止連線。|Incompatible interpretation protocol response; connection stopped.|通訳プロトコルの応答が非互換のため接続を停止しました。
    interpretation.audioFormat|同传音频格式不受支持。|同傳音訊格式不受支援。|Unsupported interpretation audio format.|通訳音声の形式がサポートされていません。
    interpretation.invalidAudio|同传音频数据无效，已停止播放。|同傳音訊資料無效，已停止播放。|Invalid interpretation audio; playback stopped.|通訳音声データが無効のため再生を停止しました。
    interpretation.bufferOverflow|音频缓冲超过上限，已停止同传。|音訊緩衝超過上限，已停止同傳。|Audio buffer limit exceeded; interpretation stopped.|音声バッファの上限を超えたため通訳を停止しました。
    interpretation.cancelled|同传操作已取消。|同傳操作已取消。|Interpretation operation cancelled.|通訳操作をキャンセルしました。
    interpretation.sessionExpired|服务会话已到期。|服務工作階段已到期。|The service session has expired.|サービスのセッション期限が切れました。
    interpretation.serviceUnavailable|同传服务暂时不可用。|同傳服務暫時不可用。|Interpretation service is temporarily unavailable.|通訳サービスは一時的に利用できません。
    interpretation.invalidRecord|同传记录无效或版本不受支持。|同傳記錄無效或版本不受支援。|Invalid or unsupported interpretation record.|通訳記録が無効か、未対応のバージョンです。
    interpretation.conflictingCaption|字幕修订冲突，已有内容未覆盖。|字幕修訂衝突，已有內容未覆寫。|Caption revision conflict; existing content was retained.|字幕の改訂が競合しています。既存の内容は保持されました。
    interpretation.sessionEnded|同传已结束，请新建会话。|同傳已結束，請新增工作階段。|Interpretation ended; create a new session.|通訳は終了しています。新しいセッションを作成してください。
    interpretation.noSourceCaptions|该字幕轨没有可导出的内容。|此字幕軌沒有可匯出的內容。|This caption track has no content to export.|この字幕トラックに出力できる内容がありません。
    interpretation.untimedSubtitleExport|字幕没有可用时间信息，请导出 TXT 或 Markdown。|字幕沒有可用時間資訊，請匯出 TXT 或 Markdown。|Captions have no timing information; export TXT or Markdown.|字幕に時刻情報がありません。TXT または Markdown を出力してください。
    mainAIUnsupportedProvider|主 AI 使用不支持同传凭据复用的服务。|主要 AI 使用不支援同傳憑證重用的服務。|The main AI provider does not support interpretation key reuse.|メイン AI の提供元は通訳キーの再利用に対応していません。
    mainAIProviderMismatch|主 AI 与所选同传厂商不同，无法复用 Key。|主要 AI 與所選同傳廠商不同，無法重用 Key。|The main AI and interpretation providers differ; the key cannot be reused.|メイン AI と通訳の提供元が異なるためキーを再利用できません。
    onlineHandshakePassed|鉴权与同传模型握手已通过|驗證身分與同傳模型交握已通過|Authentication and interpretation model handshake passed|認証と通訳モデルの接続確認に成功しました
    online.captureFailed|音频采集无法启动或停止，请检查权限、设备及采集状态。|音訊擷取無法啟動或停止，請檢查權限、裝置及擷取狀態。|Audio capture could not start or stop; check permissions, device and capture status.|音声収録を開始または停止できません。権限・デバイス・収録状態を確認してください。
    online.captureInterrupted|音源或系统状态已改变，已暂停；请手动继续。|音源或系統狀態已變更，已暫停；請手動繼續。|Capture or system state changed. Paused; resume manually.|音声入力またはシステム状態が変化したため一時停止しました。手動で再開してください。
    online-connection-gap|网络连接中断；缺口音频未补传|網路連線中斷；缺口音訊未補傳|Connection gap; missing audio was not replayed|接続中断。欠落した音声は再送しません
    online-reconnect-failed|重连失败；请检查后手动继续|重新連線失敗；請檢查後手動繼續|Reconnection failed; check the cause and resume manually|再接続に失敗しました。原因を確認し手動で再開してください
    online-session-rotation|服务会话更换；不承诺保留云端上下文|服務工作階段更換；不保證保留雲端上下文|Service session replaced; cloud context may not be retained|サービスのセッションを更新しました。文脈が保持されない場合があります
    online-start-failed|在线同传启动失败|線上同傳啟動失敗|Online interpretation could not start|オンライン通訳を開始できませんでした
    online-unsent-audio-discarded|未上传的缓冲音频已丢弃，不会补传|未上傳的緩衝音訊已捨棄，不會補傳|Unsent buffered audio was discarded and will not be replayed|未送信のバッファ音声を破棄しました。再送はしません
    tools|工具集|工具集|Tools|ツール
    setup|首次准备|首次準備|Getting started|初回の準備
    workspace|工作空间|工作空間|Workspace|ワークスペース
    projectFoldersHelp|在工作空间中新建课程，再导入课件或创建笔记。语音转写自动保存到单独位置。|在工作空間中新建課程，再匯入教材或建立筆記。語音轉寫自動儲存至獨立位置。|Create a course in the workspace, then import documents or create notes. Transcripts save automatically to a separate location.|ワークスペースでコースを作成し、教材を読み込むかノートを作成してください。文字起こしは別の保存先に自動保存されます。
    chooseProjectFirst|请先新建或选择课程。|請先新建或選擇課程。|Create or select a course first.|まずコースを作成または選択してください。
    missingAttachment|找不到课件文件，请重新定位。|找不到課件檔案，請重新定位。|Document missing. Locate it again.|教材が見つかりません。再指定してください。
    transcriptStorageUnavailable|转写保存位置未连接或不可写，请在设置中处理后再开始。|轉寫儲存位置未連接或不可寫，請在設定中處理後再開始。|The transcript location is unavailable or read-only. Resolve it in settings before starting.|文字起こしの保存先に接続できないか、書き込みできません。設定で確認してください。
    downloadOfflineModel|下载离线模型|下載離線模型|Download offline model|オフラインモデルをダウンロード
    offlineModelReady|已准备完成，可启用离线转写|已準備完成，可啟用離線轉寫|Ready for offline transcription|オフライン文字起こしを利用できます
    validationStatus|功能可用性取决于设备、权限和所选服务。|功能可用性取決於裝置、權限和所選服務。|Availability depends on your device, permissions, and selected service.|機能の利用可否はデバイス、権限、選択したサービスによって異なります。
    productSummary|连接课堂资料、听课理解与学习记录。|連結課堂資料、聽課理解與學習記錄。|Connect course materials, understanding, and study notes.|授業資料、理解、学習記録をひとつにつなげます。
    userGuide|使用指南|使用指南|User guide|使い方
    privacy|隐私说明|隱私說明|Privacy|プライバシー
    aboutApp|关于 ULecture|關於 ULecture|About ULecture|ULecture について
    refreshProjects|刷新资料|重新整理資料|Refresh materials|資料を更新
    unmountProject|从工作空间移除课程|從工作空間移除課程|Remove course from workspace|ワークスペースからコースを外す
    unmountHelp|移除只取消挂载，课程文件夹与内容将保留。|移除只取消掛載，課程資料夾與內容將保留。|The course folder and its files will stay in place.|コースフォルダとファイルはそのまま残ります。
    locateProject|重新定位课程文件夹|重新定位課程資料夾|Locate course folder|コースフォルダを再指定
    transcriptLocation|转写保存位置|轉寫儲存位置|Transcript location|文字起こしの保存先
    changeTranscriptLocation|更改转写保存位置|更改轉寫儲存位置|Change transcript location|文字起こしの保存先を変更
    migrateCourseFolder|选择课程工作文件夹并迁移|選擇課程工作資料夾並遷移|Choose course folder and migrate|コースフォルダを選択して移行
    moveUp|向上移动|向上移動|Move up|上へ移動
    moveDown|向下移动|向下移動|Move down|下へ移動
    content|内容|內容|Content|内容
    format|格式|格式|Format|形式
    transcriptOnly|仅转写|僅轉寫|Transcript only|文字起こしのみ
    transcriptBilingual|转写＋译文|轉寫＋譯文|Transcript and translation|文字起こしと翻訳
    migrateLegacy|迁移旧资料|遷移舊資料|Migrate existing library|旧ライブラリを移行
    migrateLegacyHelp|保留旧库及全部修订。先创建校验快照，再为每门课程选择工作文件夹；可稍后迁移。|保留舊庫及全部修訂。先建立驗證快照，再為每門課程選擇工作資料夾；可稍後遷移。|Keep the original library and all revisions. Create a verified snapshot, then choose a folder for each course. You can migrate later.|旧ライブラリとすべての履歴を保存します。検証済みのコピーを作り、コースごとにフォルダを選びます。後から移行することもできます。
    textTool|文本翻译|文字翻譯|Text translation|テキスト翻訳
    fileTool|文件翻译|檔案翻譯|File translation|ファイル翻訳
    voiceTool|同声传译|同聲傳譯|Live interpreting|同時通訳
    settings|设置|設定|Settings|設定
    appearance|切换外观|切換外觀|Toggle appearance|外観を切り替え
    internal|ULecture|ULecture|ULecture|ULecture
    library|本地资料库|本機資料庫|Local library|ローカルライブラリ
    libraryHelp|资料保存在你选择的位置，无需应用账号。|資料儲存在你選擇的位置，無需應用程式帳號。|Keep study materials in a folder you choose. No app account needed.|選んだフォルダに教材を保存します。アプリのアカウントは不要です。
    offline|离线转写|離線轉寫|Offline transcription|オフライン文字起こし
    prepare|准备离线转写|準備離線轉寫|Prepare transcription|文字起こしを準備
    importModel|导入已有模型|匯入現有模型|Import downloaded model|既存モデルを読み込む
    download|下载并校验|下載並驗證|Download and verify|ダウンロードして検証
    modelHelp|英语、日语在本机处理。当前基础模型的日语质量仍待改进。|英語、日語在本機處理。目前基礎模型的日語品質仍待改善。|English and Japanese are processed locally. Japanese accuracy with this base model still needs improvement.|英語と日本語を端末内で処理します。現モデルの日本語精度には改善が必要です。
    soundCheck|试音|試音|Sound check|音声入力テスト
    soundCheckHelp|点击后采集所选音源，15 秒自动停止。请自行说话或开始网课声音；本程序不会播放示例。|點擊後擷取所選音源，15 秒自動停止。請自行說話或開始網課聲音；本程式不會播放範例。|Click to capture the selected source for up to 15 seconds. Speak or start your lesson audio yourself; the app plays no sample.|クリックすると選択した音声を最長15秒収録します。ご自身で話すか授業音声を開始してください。サンプル音声は再生しません。
    soundCheckStart|开始试音（15 秒）|開始試音（15 秒）|Start 15-second check|15秒のテストを開始
    soundCheckStop|停止试音|停止試音|Stop check|テストを停止
    soundCheckStopped|试音已停止|試音已停止|Sound check stopped|音声入力テストを停止しました
    soundCheckLimit|已到 15 秒，试音已停止|已達 15 秒，試音已停止|15-second limit reached; sound check stopped|15秒が経過し、テストを停止しました
    soundCheckTemporary|试音仅保留本页临时文字，不保存录音、不加入课堂，也不发送到云服务。|試音僅保留本頁暫存文字，不儲存錄音、不加入課堂，也不傳送至雲端服務。|Test text exists only on this page. No recording is saved, no classroom is created, and nothing is sent to cloud services.|テストの文字はこの画面だけに一時表示します。録音の保存・授業への追加・クラウド送信は行いません。
    soundCheckWaiting|开始试音后，在此查看实际识别文字。|開始試音後，在此查看實際辨識文字。|Start a check to see the actual recognized text here.|テストを開始すると、実際の認識結果がここに表示されます。
    soundCheckClassActive|请先暂停课堂，再使用独立试音。|請先暫停課堂，再使用獨立試音。|Pause the classroom before using this separate sound check.|授業の収録を一時停止してから、音声入力テストを使用してください。
    optionalCloud|可选云服务|可選雲端服務|Optional cloud services|任意のクラウドサービス
    classTerminology|课程术语|課程術語|Course terminology|コースの用語集
    enableClassTerminology|此课堂使用课程术语|此課堂使用課程術語|Use course terms in this class|この授業でコースの用語を使う
    classTerminologyHelp|仅明确开启后生效。使用已保存的课程术语快照；修改术语后可在此更新。已发起请求及其重试保留原快照，不影响其他课堂。|僅明確開啟後生效。使用已儲存的課程術語快照；修改術語後可在此更新。已發起請求及其重試保留原快照，不影響其他課堂。|Applies only when enabled. Uses a saved course glossary snapshot; update it here after editing terms. Dispatched requests and retries retain their original snapshot. Other classes are unchanged.|有効にすると、保存したコース用語集のスナップショットを使います。編集後はここで更新できます。送信済みの依頼と再試行は元の内容を保持し、他の授業には影響しません。
    terminologyEntries|条术语|條術語|terms|件の用語
    updateTerminologySnapshot|使用最新已保存术语|使用最新已儲存術語|Use latest saved terms|最新の保存済み用語を使う
    noCourseTerminology|该课程还没有已启用的术语。|此課程還沒有已啟用的術語。|No enabled terms in this course yet.|このコースには有効な用語がまだありません。
    manageCourseTerminology|管理此课程术语|管理此課程術語|Manage course terms|コースの用語を管理
    cloudHelp|配置后可使用课堂、文本与文件翻译，以及 AI 问答、笔记和总结。保存设置不会发送请求。|設定後可使用課堂、文字與檔案翻譯，以及 AI 問答、筆記和摘要。儲存設定不會傳送請求。|Configure classroom, text and file translation, plus AI questions, notes and summaries. Saving settings sends no request.|授業・テキスト・ファイルの翻訳や、AIへの質問・ノート・要約を利用できます。設定の保存ではリクエストを送信しません。
    hideSetup|不再显示|不再顯示|Hide this page|今後表示しない
    restoreSetup|打开首次准备|開啟首次準備|Open getting started|初回の準備を開く
    new|新建|新增|New|新規
    course|课程|課程|Course|コース
    folder|文件夹|資料夾|Folder|フォルダ
    classroom|课堂|課堂|Classroom|授業
    note|笔记|筆記|Note|ノート
    pdf|PDF|PDF|PDF|PDF
    rename|重命名|重新命名|Rename|名前を変更
    move|移动到|移動到|Move to|移動先
    delete|移到最近删除|移至最近刪除|Move to recently deleted|最近削除した項目へ移動
    deleteHelp|资料仍保留，可在最近删除中恢复。未结束的课堂必须先结束。|資料仍保留，可在最近刪除中復原。未結束的課堂必須先結束。|Materials remain recoverable. Finish unfinished classrooms before deleting.|データは復元可能です。未終了の授業は先に終了してください。
    undoDelete|撤销上次删除|復原上次刪除|Undo last deletion|直前の削除を取り消す
    trash|最近删除|最近刪除|Recently deleted|最近削除した項目
    restore|恢复|復原|Restore|復元
    root|工作空间根目录|工作空間根目錄|Workspace root|ワークスペースのルート
    open|打开|開啟|Open|開く
    cancel|取消|取消|Cancel|キャンセル
    save|保存|儲存|Save|保存
    saved|已保存|已儲存|Saved|保存済み
    saving|正在保存…|正在儲存…|Saving…|保存中…
    storageBackpressure|保存速度不足，采集已暂停；请等待保存完成后继续。|儲存速度不足，擷取已暫停；請等待儲存完成後繼續。|Capture paused because saving could not keep up. Wait for saving to finish, then resume.|保存が追いつかないため収録を一時停止しました。保存完了後に再開してください。
    saveFailed|保存失败，草稿仍保留|儲存失敗，草稿仍保留|Save failed; draft retained|保存失敗・下書きは保持されています
    retry|重试|重試|Retry|再試行
    copy|复制|複製|Copy|コピー
    close|关闭|關閉|Close|閉じる
    importPDF|导入资料|匯入資料|Import materials|資料を読み込む
    pdfHelp|可打开 PDF、PPT 和 PPTX 并标注。演示稿在本机转换为静态页面；AI 来源面板会说明文字提取与未覆盖范围。|可開啟 PDF、PPT 和 PPTX 並標註。簡報在本機轉換為靜態頁面；AI 來源面板會說明文字擷取與未涵蓋範圍。|Open and annotate PDF, PPT and PPTX. Presentations convert locally to static pages; AI sources show extracted text and coverage limits.|PDF・PPT・PPTXを開いて注釈できます。スライドはローカルで静的ページに変換され、AIの資料欄に抽出テキストと対象外の範囲を表示します。
    page|页码|頁碼|Page|ページ
    fit|适合宽度|符合寬度|Fit width|幅に合わせる
    notes|文字笔记|文字筆記|Notes|ノート
    transcript|转写与翻译|轉寫與翻譯|Transcript & translation|文字起こしと翻訳
    summary|课后 AI|課後 AI|After-class AI|授業後の AI
    heading|标题|標題|Heading|見出し
    list|列表|清單|List|リスト
    bold|加粗|粗體|Bold|太字
    pageRef|引用当前页|引用目前頁面|Cite current page|現在のページを引用
    preview|预览|預覽|Preview|プレビュー
    edit|编辑|編輯|Edit|編集
    start|开始课堂|開始課堂|Start classroom|授業を開始
    pause|暂停|暫停|Pause|一時停止
    resume|继续|繼續|Resume|再開
    end|结束课堂|結束課堂|End classroom|授業を終了
    draft|尚未开始|尚未開始|Not started|未開始
    preparing|正在准备|正在準備|Preparing|準備中
    ready|已就绪|已就緒|Ready|準備完了
    capturing|正在采集|正在擷取|Capturing|収録中
    paused|已暂停|已暫停|Paused|一時停止中
    interrupted|上次课堂意外中断|上次課堂意外中斷|Previous classroom interrupted|前回の授業が中断されました
    ended|已结束|已結束|Ended|終了済み
    source|音频来源|音訊來源|Audio source|音声入力元
    microphone|麦克风|麥克風|Microphone|マイク
    systemAudio|系统音频|系統音訊|System audio|システム音声
    device|输入设备|輸入裝置|Input device|入力デバイス
    refresh|刷新|重新整理|Refresh|更新
    mainLanguage|课堂主要语言|課堂主要語言|Classroom language|授業の言語
    targetLanguage|中文译文|中文譯文|Chinese translation|中国語訳
    recording|保存录音|儲存錄音|Save recording|録音を保存
    recordingHelp|只保存开启后实际采集的音频；之前未保存的内容不能回补。|僅儲存開啟後實際擷取的音訊；之前未儲存的內容不能補回。|Only audio captured while enabled is saved. Earlier audio cannot be recovered.|有効時に収録した音声のみ保存します。過去の音声は復元できません。
    speech|普通话播报|普通話播報|Mandarin speech|普通話の読み上げ
    speechHelp|麦克风与播报同时使用时请佩戴耳机。使用系统音频时，请确认播报没有被重复采集。|同時使用麥克風及播報時請佩戴耳機。使用系統音訊時，請確認播報沒有被重複擷取。|Wear headphones when using microphone capture and speech playback together. With system audio, check that speech playback is not captured again.|マイク収録と読み上げを併用するときはヘッドホンを使用してください。システム音声では、読み上げが再収録されていないことを確認してください。
    stopSound|停止声音|停止聲音|Stop sound|音声を停止
    provisional|正在识别 · 未确认|正在辨識 · 未確認|Recognizing · provisional|認識中・未確定
    noTranscript|确认的原文将在这里显示。|已確認的原文會顯示於此。|Confirmed transcript will appear here.|確定した文字起こしがここに表示されます。
    pendingTranslation|等待翻译|等待翻譯|Waiting for translation|翻訳待ち
    pauseTranslation|暂停翻译/补译|暫停翻譯/補譯|Pause translations|翻訳を一時停止
    resumeTranslation|继续翻译/补译|繼續翻譯/補譯|Resume translations|翻訳を再開
    noRecording|此段未保存录音|此段未儲存錄音|No recording for this interval|この区間の録音はありません
    play|回听|回聽|Play recording|録音を再生
    generateSummary|生成总结|產生總結|Generate summary|要約を生成
    summaryHelp|结束课堂后，可将本课堂选定的 PDF 文字、已确认转写和已保存笔记发送到所选服务。|結束課堂後，可將本課堂所選的 PDF 文字、已確認轉寫及已儲存筆記傳送至所選服務。|After ending the classroom, send selected PDF text, confirmed transcript and saved notes to the selected service.|授業終了後、この授業の選択した PDF テキスト・確定文字起こし・保存済みノートを選択サービスへ送信します。
    aiLabel|AI 生成，请结合来源核对|AI 產生，請配合來源核對|AI generated; check against sources|AI 生成・出典を確認してください
    appendNotes|追加到笔记|附加至筆記|Append to notes|ノートに追記
    sources|来源与覆盖|來源與涵蓋範圍|Sources & coverage|出典と対象範囲
    future|AI 助手|AI 助理|AI assistant|AI アシスタント
    futureHelp|选择资料后使用右侧 AI 助手。|選擇資料後使用右側 AI 助理。|Select materials to use the AI assistant.|資料を選択して AI アシスタントを利用できます。
    general|通用|一般|General|一般
    language|界面语言|介面語言|Interface language|表示言語
    followSystem|跟随系统|跟隨系統|Follow system|システムに従う
    service|AI 服务|AI 服務|AI service|AI サービス
    provider|服务接入方式|服務接入方式|Service access path|サービス接続方式
    credential|凭据|憑證|Credential|認証情報
    saveCredential|保存到钥匙串|儲存至鑰匙圈|Save to Keychain|キーチェーンに保存
    unlockCredential|为本次运行启用云请求|為本次執行啟用雲端請求|Enable cloud requests for this run|今回の起動でクラウド通信を有効化
    removeCredential|移除凭据|移除憑證|Remove credential|認証情報を削除
    testService|测试连接（可能计费）|測試連線（可能計費）|Test connection (may incur cost)|接続テスト（課金の可能性あり）
    cloudConsent|只有主动启用后才发送课堂文字。更换服务也会更改待翻译任务的服务；不会自动更换厂家。|僅主動啟用後才傳送課堂文字。更換服務亦會更改待翻譯工作的服務；不會自動更換廠商。|Cloud requests send classroom text only after explicit enablement. Changing the service rebinds pending translations. Providers never switch automatically.|明示的な有効化後に授業テキストを送信します。サービス変更は待機中の翻訳にも適用されます。提供元は自動変更されません。
    unknownCost|费用未知；如提供金额，仅为估算，并非账单或硬性上限。|費用未知；如提供金額，僅為估算，並非帳單或硬性上限。|Cost unknown. Any amount is an estimate, not a bill or spending cap.|料金は不明です。金額は見積もりであり、請求額や利用上限ではありません。
    help|帮助与限制|說明與限制|Help & limitations|ヘルプと制限
    openFolder|在 Finder 显示|在 Finder 顯示|Show in Finder|Finder で表示
    export|导出|匯出|Export|書き出す
    readableExport|导出文字与字幕|匯出文字與字幕|Export text and subtitles|テキストと字幕を書き出す
    pauseBeforeRemove|请先暂停该课程正在进行的采集，再移除课程。|請先暫停該課程正在進行的擷取，再移除課程。|Pause this course’s active capture before removing it.|コースを取り外す前に進行中の収音を一時停止してください。
    endBeforeDelete|此范围包含尚未结束的课堂。请先结束并保存课堂，再删除。|此範圍包含尚未結束的課堂。請先結束並儲存課堂，再刪除。|This selection contains an unfinished class. End and save the class before deleting it.|選択範囲に未終了の授業があります。終了して保存してから削除してください。
    projectOffline|资料位置不可用。已保存记录保留；请连接磁盘或在设置中重新定位。|資料位置無法使用。已儲存記錄保留；請連接磁碟或在設定中重新定位。|The file location is unavailable. Saved records are retained; reconnect the disk or locate the folder in Settings.|資料の場所を利用できません。保存済み記録は保持されています。ディスクを接続するか設定で場所を指定してください。
    legacyMaterials|旧资料|舊資料|Legacy materials|旧データ
    legacyPreflight|重新预检旧资料|重新預檢舊資料|Recheck legacy source|旧データを再確認
    legacyPreflightHelp|创建新的冻结快照，保留以前的迁移与后续编辑；不会覆盖已导入资料。|建立新的凍結快照，保留以前的遷移與後續編輯；不會覆蓋已匯入資料。|Create a new frozen snapshot, preserving earlier migrations and subsequent edits. Imported work is not replaced.|以前の移行とその後の編集を保持して新しい固定スナップショットを作成します。取り込み済みの資料は置き換えません。
    backupHelp|备份所选资料及其完整引用、文档版本、笔记资源、批注和已保存会话。恢复到新文件夹，不覆盖已有资料；不包含密钥或模型。|備份所選資料及其完整引用、文件版本、筆記資源、批註和已儲存會話。復原至新資料夾，不覆蓋已有資料；不含金鑰或模型。|Back up the selection with its references, document versions, note resources, annotations and saved sessions. Restore into new folders without replacing existing work. Keys and models are excluded.|選択した資料と参照、文書の版、ノート素材、注釈、保存済みセッションをバックアップします。既存の資料を上書きせず新しいフォルダに復元します。キーとモデルは含みません。
    backupScope|备份范围|備份範圍|Backup scope|バックアップ範囲
    restoreLocation|选择恢复位置|選擇復原位置|Choose restore location|復元先を選択
    backup|完整备份|完整備份|Complete backup|完全バックアップ
    restoreBackup|从备份恢复|從備份復原|Restore from backup|バックアップから復元
    exportDone|导出已完成|匯出已完成|Export completed|書き出し完了
    noItems|建立课程，开始整理本地学习资料。|建立課程，開始整理本機學習資料。|Create a course to organize your study materials.|コースを作成して学習資料を整理しましょう。
    selectItem|从工作空间选择资料|從工作空間選擇資料|Select an item in the workspace|ワークスペースから項目を選択
    name|名称|名稱|Name|名前
    error|需要处理|需要處理|Action needed|対応が必要です
    permission|权限状态|權限狀態|Permission status|権限の状態
    permissionHelp|仅在你开始所选音源时申请对应权限。打开程序不会自动采集或发声。|僅在你開始所選音源時申請對應權限。開啟程式不會自動擷取或發聲。|Permission is requested only when you start the selected source. Opening the app never starts capture or sound.|選択した入力を開始するときだけ権限を要求します。起動時に収録や再生は開始しません。
    pendingValidation|尚未获得权限|尚未取得權限|Permission not granted|権限が許可されていません
    noPDF|尚未导入 PDF|尚未匯入 PDF|No PDF imported|PDF は未読み込みです
    selectedMaterials|选择总结资料|選擇總結資料|Select summary materials|要約の資料を選択
    noteSnapshot|生成时的笔记|產生時的筆記|Notes at generation time|生成時のノート
    changeLibrary|打开另一资料库|開啟另一資料庫|Open another library|別のライブラリを開く
    busy|正在处理…|正在處理…|Working…|処理中…
    confirm|确认|確認|Confirm|確認
    sidebar|显示/隐藏侧栏|顯示/隱藏側欄|Toggle sidebar|サイドバーを切り替え
    lastSaved|最近成功保存|最近成功儲存|Last successful save|最終保存
    gaps|采集间断|擷取間斷|Capture gaps|収録の中断
    latest|回到最新内容|回到最新內容|Back to latest|最新へ戻る
    waitingConfiguration|等待设置服务|等待設定服務|Waiting for service setup|サービス設定待ち
    waitingNetwork|等待联网|等待連線|Waiting for network|ネットワーク接続待ち
    queued|等待处理|等待處理|Queued|処理待ち
    running|正在处理|正在處理|Processing|処理中
    retryWaiting|等待有限重试|等待有限重試|Waiting for bounded retry|回数制限付きの再試行待ち
    completed|已完成|已完成|Completed|完了
    needsAttention|需要手动处理|需要手動處理|Manual action required|手動対応が必要
    obsolete|原文已更新，此结果已过时|原文已更新，此結果已過時|Source updated; result obsolete|原文が更新され、この結果は古くなっています
    partial|部分完成|部分完成|Partially completed|一部完了
    cancelled|已取消；已发送请求仍可能计费|已取消；已傳送請求仍可能計費|Cancelled; sent requests may still incur cost|キャンセル済み・送信済みリクエストは課金される場合があります
    failed|失败，需要处理|失敗，需要處理|Failed; action required|失敗・対応が必要
    idle|等待新内容|等待新內容|Waiting for new content|新しい内容を待機中
    userPaused|用户已暂停|使用者已暫停|Paused by you|ユーザー操作で一時停止中
    unverified|尚未验证连接或账户|尚未驗證連線或帳號|Connection and account unverified|接続・アカウントは未検証
    testing|正在测试连接（可能计费）|正在測試連線（可能計費）|Testing connection (may incur cost)|接続をテスト中（課金の可能性あり）
    requestSucceededAccountUnverified|本次连接成功；后续可用性、地区限制与费用以服务商账户为准|本次連線成功；後續可用性、地區限制與費用以服務商帳戶為準|Connection succeeded. Future access, regional restrictions and charges depend on your provider account.|接続に成功しました。以降の利用可否・地域制限・料金は提供元のアカウントによって異なります。
    missingCredential|服务未配置或凭据未解锁|服務未設定或憑證未解鎖|Service unconfigured or credentials locked|サービス未設定または認証情報が未有効化
    invalidConfiguration|服务项目或区域设置无效|服務專案或區域設定無效|Invalid service project or region|サービスのプロジェクトまたはリージョン設定が無効
    expiredPreset|模型已停用，请更新应用后重试|模型已停用，請更新應用程式後重試|This model has retired. Update the app and retry.|このモデルは提供を終了しました。アプリを更新して再試行してください
    cloudNetwork|连接失败，原文仍保留|連線失敗，原文仍保留|Connection failed; transcript retained|接続に失敗しました。原文は保持しています
    authentication|凭据无效或过期，请在设置中替换|憑證無效或過期，請在設定中更換|Credentials invalid or expired; replace them in Settings|認証情報が無効または期限切れです。設定で更新してください
    cloudPermission|服务拒绝访问，请核对权限及地区资格|服務拒絕存取，請核對權限及地區資格|Access denied; check permissions and regional eligibility|アクセスが拒否されました。権限と対象地域を確認してください
    quota|额度或计费不可用，请查看服务账户|配額或計費不可用，請查看服務帳號|Quota or billing unavailable; check the service account|利用枠または課金を利用できません。サービスのアカウントを確認してください
    rateLimited|请求受限，等待有限重试|請求受限，等待有限重試|Rate limited; waiting for bounded retry|リクエスト制限中・回数制限付きの再試行待ち
    unavailable|当前服务或模型暂不可用|目前服務或模型暫時無法使用|Current service or model unavailable|現在のサービスまたはモデルは利用できません
    malformedResponse|响应缺失、截断或无法核对来源|回應缺失、截斷或無法核對來源|Response missing, truncated or not verifiable against sources|応答が欠落・切り詰められたか、出典を確認できません
    persistence|结果未保存；已停止派发并保留草稿|結果未儲存；已停止派送並保留草稿|Result unsaved; dispatch stopped and draft retained|結果は未保存です。送信を停止し下書きを保持しています
    queueFull|待翻译队列已满；原文仍保留|待翻譯佇列已滿；原文仍保留|Translation queue full; transcript retained|翻訳待ちが上限に達しました。原文は保持しています
    noMaterials|没有可用的已保存课堂文字|沒有可用的已儲存課堂文字|No saved classroom text available|利用できる保存済み授業テキストがありません
    responseTooLarge|超出处理上限；未处理范围仍保留|超出處理上限；未處理範圍仍保留|Processing limit exceeded; unprocessed coverage retained|処理上限を超えました。未処理範囲は保持しています
    interruptedUsageUnknown|请求曾被中断，结果与费用未知；需手动处理|請求曾被中斷，結果及費用未知；須手動處理|Request interrupted; outcome and cost unknown. Manual action required|通信が中断しました。結果と料金は不明です。手動対応が必要です
    pausedNoAudio|暂停期间未采集音频|暫停期間未擷取音訊|No audio captured during pause|一時停止中は音声を収録していません
    storageFailure|保存失败，采集已暂停|儲存失敗，擷取已暫停|Save failed; capture paused|保存失敗により収録を一時停止しました
    windowClosed|窗口关闭，采集已暂停|視窗關閉，擷取已暫停|Window closed; capture paused|ウインドウを閉じたため収録を一時停止しました
    applicationClosed|应用关闭，采集已暂停|應用程式關閉，擷取已暫停|App closed; capture paused|アプリの終了により収録を一時停止しました
    asrOverload|识别积压，此区间音频未转写|辨識積壓，此區間音訊未轉寫|Recognition overloaded; this audio interval was not transcribed|認識処理が追いつかず、この音声区間は文字起こしされていません
    asrUnconfirmedTail|识别失败，尾部未确认|辨識失敗，尾部未確認|Recognition failed; remaining audio unconfirmed|認識に失敗しました。末尾は未確定です
    estimatedGap|中断间隔按系统时间估算；此间未采集音频|中斷間隔按系統時間估算；此間未擷取音訊|Interruption interval estimated from wall time; no audio was captured|中断区間はシステム時刻から推定しています。この間の音声は未収録です
    savedRecordings|已保存录音范围|已儲存錄音範圍|Saved recording ranges|保存済み録音の範囲
    recordingOffset|当前录音块内位置|目前錄音區塊內位置|Position within this recording chunk|現在の録音ブロック内の位置
    subtitleSize|字幕字号|字幕字級|Subtitle size|字幕サイズ
    zoomOut|缩小|縮小|Zoom out|縮小
    zoomIn|放大|放大|Zoom in|拡大
    projectID|Google Cloud 项目 ID|Google Cloud 專案 ID|Google Cloud project ID|Google Cloud プロジェクト ID
    location|Google Cloud 区域|Google Cloud 區域|Google Cloud location|Google Cloud ロケーション
    apiKey|API 密钥|API 金鑰|API key|API キー
    oauthCredential|OAuth 令牌或服务账号 JSON|OAuth 權杖或服務帳號 JSON|OAuth token or service-account JSON|OAuth トークンまたはサービスアカウント JSON
    serviceDistinction|ChatGPT 订阅不含 API 凭据。Developer API 和 Cloud 为不同产品。Standard 需项目与令牌或服务账号；Express 使用其独立密钥。|ChatGPT 訂閱不含 API 憑證。Developer API 和 Cloud 是不同產品。Standard 需專案及權杖或服務帳號；Express 使用其獨立金鑰。|A ChatGPT subscription is not an API credential. Developer API and Cloud are separate products. Standard needs a project and token or service account; Express uses its own key.|ChatGPT のサブスクリプションは API 認証情報ではありません。Developer API と Cloud は別製品です。Standard にはプロジェクトとトークンまたはサービスアカウント、Express には専用キーが必要です。
    licensePending|项目源码采用 AGPL-3.0-only；第三方组件保留各自许可，声明随应用附带。|專案原始碼採用 AGPL-3.0-only；第三方元件保留各自授權條款，聲明隨應用附帶。|Source code: AGPL-3.0-only. Third-party components retain their own licenses; notices are included.|ソースコードは AGPL-3.0-only。第三者コンポーネントには各自のライセンスが適用され、表記を同梱しています。
    readOnly|资料库只读，不能保存修改|資料庫唯讀，不能儲存修改|Read-only library; edits cannot be saved|読み取り専用ライブラリ・変更は保存できません
    summaryStale|总结生成后资料已更新；此总结仍使用原快照|總結產生後資料已更新；此總結仍使用原快照|Materials changed after generation; this summary retains its original snapshot|生成後に資料が更新されました。この要約は元のスナップショットを使用します
    summaryPartial|总结仅覆盖已完成部分，未完成范围仍可查看|總結僅涵蓋已完成部分，仍可查看未完成範圍|Summary covers completed portions only; unprocessed coverage remains visible|要約は完了した部分のみを対象とします。未処理範囲を確認できます
    missingChunks|未完成分块|未完成分塊|Unfinished chunks|未完了の分割処理
    invalidReferences|无效引用已排除|無效引用已排除|Invalid references excluded|無効な参照を除外済み
    includedSources|已纳入来源|已納入來源|Included sources|対象の出典
    excludedSources|未分析范围|未分析範圍|Unanalyzed coverage|未解析の範囲
    noVerifiableReference|无可核实来源|無可核實來源|No verifiable source|検証可能な出典なし
    noteUnsaved|笔记尚未保存，请重试或复制草稿|筆記尚未儲存，請重試或複製草稿|Note not saved; retry or copy the draft|ノートは未保存です。再試行するか下書きをコピーしてください
    pendingUnsaved|仍有未保存内容，请处理后再关闭或切换资料库|仍有未儲存內容，請處理後再關閉或切換資料庫|Unsaved content remains; resolve it before closing or switching libraries|未保存の内容があります。解決してから終了またはライブラリを切り替えてください
    waitingDrain|正在保存识别尾部，请稍候|正在儲存辨識尾部，請稍候|Saving remaining recognition results; please wait|認識結果の末尾を保存中です。お待ちください
    summaryStopped|总结已停止；已完成部分保留|總結已停止；已完成部分保留|Summary stopped; completed portions retained|要約を停止しました。完了した部分は保持しています
    libraryClosed|资料库已关闭|資料庫已關閉|Library closed|ライブラリは閉じられました
    libraryUnavailable|资料库无法使用|資料庫無法使用|Library unavailable|ライブラリを利用できません
    recordingLinkRejected|录音暂存包含不安全链接，未导入|錄音暫存包含不安全連結，未匯入|Recording staging contains an unsafe link; not imported|録音の一時保存に安全でないリンクがあります。読み込んでいません
    configurationChanged|音源或设置已改变；请手动继续|音源或設定已變更；請手動繼續|Source or settings changed; resume manually|入力元または設定を変更しました。手動で再開してください
    currentQueue|当前待译|目前待譯|Current pending|現在の翻訳待ち
    historicalQueue|历史补译|歷史補譯|Historical catch-up|過去の未翻訳分
    historyTranslating|正在补译历史内容|正在補譯歷史內容|Translating historical text|過去の未翻訳分を処理中
    historyPriorityHelp|优先处理当前讲话，历史内容利用剩余额度补译且不自动播报。|優先處理目前講話，歷史內容利用剩餘額度補譯且不自動播報。|Current speech takes priority. Older text uses remaining capacity and is never read aloud automatically.|現在の発話を優先します。過去の未翻訳分は余裕があるときに処理し、自動では読み上げません。
    checkServiceSettings|检查服务设置|檢查服務設定|Check service settings|サービス設定を確認
    attempts|已尝试次数|已嘗試次數|Attempts|試行回数
    nextRetry|下次最早重试时间|下次最早重試時間|Earliest next retry|次回の最短再試行時刻
    retryService|手动重试将使用|手動重試將使用|Manual retry will use|手動再試行の送信先
    requestHistory|已发送请求与服务|已傳送請求及服務|Sent requests and services|送信済みリクエストとサービス
    notQueued|原文已保存，尚未登记翻译任务|原文已儲存，尚未登記翻譯工作|Transcript saved; translation task not yet queued|原文は保存済みですが、翻訳は未登録です
    reconcileTranslations|将未登记原文加入补译|將未登記原文加入補譯|Queue missing translations|未登録の原文を翻訳待ちに追加
    sentMayCharge|已发送的请求仍可能计费；超时后重试可能再次产生用量。|已傳送的請求仍可能計費；逾時後重試可能再次產生用量。|Sent requests may still incur cost. Retrying after a timeout may incur usage again.|送信済みリクエストは課金される場合があります。タイムアウト後の再試行でも使用量が発生する可能性があります。
    recordedUsage|本机已记录用量|本機已記錄用量|Locally recorded usage|この端末に記録した使用量
    usageScope|仅统计此处已记录的请求；未知用量未计入 token 合计，不能当作零。|僅統計此處已記錄的請求；未知用量未計入 token 合計，不能當作零。|Only requests recorded here are counted. Unknown usage is excluded from token totals and is not zero.|ここに記録されたリクエストのみを集計します。不明な使用量はトークン合計に含まれず、ゼロを意味しません。
    noUsage|尚无已记录的服务用量|尚無已記錄的服務用量|No recorded service usage|サービス使用量の記録はありません
    requests|请求记录|請求記錄|Request records|リクエスト記録
    unknownUsage|用量未知|用量未知|Usage unknown|使用量不明
    knownTokens|已知 token 合计|已知 token 合計|Known token totals|既知のトークン合計
    inputTokens|输入 token|輸入 token|Input tokens|入力トークン
    outputTokens|输出 token|輸出 token|Output tokens|出力トークン
    providerReported|服务返回值|服務回傳值|Provider reported|サービスの返却値
    showMore|显示更多|顯示更多|Show more|さらに表示
    speechSkipped|为跟上课堂，已跳过部分语音；文字已保留|為跟上課堂，已略過部分語音；文字已保留|Some speech was skipped to keep up; all text is retained|授業に追いつくため一部の音声を省略しました。テキストは保持しています
    refreshVoices|重新检查普通话声音|重新檢查普通話聲音|Check Mandarin voices again|普通話の音声を再確認
    willSendMaterials|本次将发送的文字范围|本次將傳送的文字範圍|Text selected for this request|今回送信するテキストの範囲
    notSelected|未选择，不发送|未選擇，不傳送|Not selected; not sent|未選択・送信しません
    readablePages|可提取文字页码|可擷取文字頁碼|Pages with extractable text|文字を抽出できたページ
    noPDFForSummary|本次未使用课件文字；只处理选定的转写与笔记。|本次未使用課件文字；僅處理所選的轉寫及筆記。|No course PDF text is included; only selected transcript and notes are used.|教材 PDF のテキストは含まれません。選択した文字起こしとノートのみを使用します。
    confirmedTranscript|已确认原文|已確認原文|Confirmed transcript|確定した原文
    segments|片段|片段|segments|区間
    characters|字符|字元|characters|文字
    summaryGapNotice|转写包含采集间断；没有采集或确认的内容不会纳入总结。|轉寫包含擷取間斷；未擷取或未確認的內容不會納入總結。|The transcript includes capture gaps. Uncaptured or unconfirmed material is excluded.|収録の中断があります。未収録または未確定の内容は要約に含めません。
    emptySavedNotes|尚无可用的已保存笔记文字|尚無可用的已儲存筆記文字|No saved note text available|利用できる保存済みノートの本文はありません
    summarySavesDraft|当前草稿会先保存，再固定为本次总结的来源版本；保存失败不会发送。|目前草稿會先儲存，再固定為本次總結的來源版本；儲存失敗不會傳送。|The current draft is saved before its version is fixed for this summary. A save failure prevents sending.|現在の下書きを保存してから、今回の要約に使用するバージョンを固定します。保存に失敗した場合は送信しません。
    allClassNotes|本课堂全部文字笔记|本課堂全部文字筆記|All notes in this classroom|この授業のすべてのノート
    processedChunks|已处理部分|已處理部分|Processed portions|処理済みの部分
    allCoverage|查看全部来源及实际处理范围|查看全部來源及實際處理範圍|View all sources and processed coverage|すべての出典と処理範囲を表示
    retrySnapshot|重试此资料快照|重試此資料快照|Retry this material snapshot|この資料スナップショットを再試行
    retrySnapshotHelp|使用原资料版本重新生成并保留旧结果，可能产生新的用量。当前目标服务|使用原資料版本重新產生並保留舊結果，可能產生新的用量。目前目標服務|Regenerate using the original material versions while retaining old results; new usage may occur. Current service|元の資料バージョンで再生成し、以前の結果を保持します。新たな使用量が発生する場合があります。現在のサービス
    sourceSnapshotOnly|当前原资料无法准确定位，显示生成时保存的文字快照。|目前原資料無法準確定位，顯示產生時儲存的文字快照。|The current original cannot be located exactly. Showing the text snapshot saved at generation time.|現在の原資料を正確に特定できないため、生成時に保存したテキストを表示します。
    notesAndSummaries|笔记与总结|筆記及總結|Notes and summaries|ノートと要約
    transcriptsAndTranslations|转写与译文（含字幕）|轉寫及譯文（含字幕）|Transcript and translation, including subtitles|文字起こしと翻訳（字幕を含む）
    showInFinder|在 Finder 中显示|在 Finder 中顯示|Show in Finder|Finder で表示
    noExtractableText|没有提取到可用于总结的课件文字|未擷取到可用於總結的課件文字|No course text could be extracted for summaries|要約に使用できる教材の文字を抽出できませんでした
    textPages|可提取文字页|可擷取文字頁|Pages with text|文字を抽出できたページ
    unreadablePages|无可提取文字页|無可擷取文字頁|Pages without extractable text|文字を抽出できないページ
    pdfLoadFailed|PDF 无法读取|PDF 無法讀取|Unable to read PDF|PDF を読み取れません
    resizePanel|调整面板宽度|調整面板寬度|Resize panel|パネル幅を調整
    showNotes|显示笔记|顯示筆記|Show notes|ノートを表示
    hideNotes|收起笔记|收起筆記|Hide notes|ノートを閉じる
    closeSidePanel|收起侧栏|收起側欄|Close side panel|サイドパネルを閉じる
    classRecords|课堂记录|課堂記錄|Classroom records|授業記録
    otherMaterials|其他资料|其他資料|Other materials|その他の資料
    recordingAvailable|已保存录音|已儲存錄音|Recording saved|録音を保存済み
    noteLoadFailed|笔记读取失败，请重试后再编辑|筆記讀取失敗，請重試後再編輯|Unable to load note; retry before editing|ノートを読み込めません。再試行してから編集してください
    loading|正在读取|正在讀取|Loading|読み込み中
    elapsedTime|课堂时间|課堂時間|Class time|授業時間
    serviceGuide|接入步骤|接入步驟|Setup steps|接続の手順
    guideCredential|准备对应凭据|準備對應憑證|Prepare the correct credential|対応する認証情報を準備
    guideBilling|确认资格、计费与额度|確認資格、計費及配額|Check eligibility, billing and quota|利用資格・課金・利用枠を確認
    guideConnect|在本应用启用和检查|在本應用程式啟用及檢查|Enable and check in this app|このアプリで有効化して確認
    guideOpenAI1|在 OpenAI API 平台创建你自己的 API key；ChatGPT 订阅和 API 计费分开，不能填 ChatGPT 登录凭据。|在 OpenAI API 平台建立你自己的 API key；ChatGPT 訂閱及 API 計費分開，不能填入 ChatGPT 登入憑證。|Create your own API key on the OpenAI API platform. ChatGPT subscriptions and API billing are separate; do not enter ChatGPT login credentials.|OpenAI API プラットフォームでご自身の API キーを作成します。ChatGPT の契約と API の課金は別です。ChatGPT のログイン情報は入力しないでください。
    guideOpenAI2|在官方账户页面确认所在地区是否受支持，以及 API 资格、模型权限和额度。本应用不会代你开通计费。|在官方帳戶頁面確認所在地區是否受支援，以及 API 資格、模型權限和配額。本應用程式不會代你啟用計費。|Check regional availability, API eligibility, model access and quota on the official account pages. This app does not enable billing for you.|公式アカウント画面で対象地域、API 利用資格、モデル権限、利用枠を確認してください。本アプリが課金を有効にすることはありません。
    guideOpenAI3|在本页选择 OpenAI API 并保存设置，将 API key 保存到钥匙串，再明确启用本次云请求。连接测试可能计费，成功只代表该次请求成功。|在本頁選擇 OpenAI API 並儲存設定，將 API key 儲存至鑰匙圈，再明確啟用本次雲端請求。連線測試可能計費，成功僅代表該次請求成功。|Select OpenAI API and save settings, save the API key to Keychain, then explicitly enable cloud requests for this run. A connection test may incur cost and proves only that request succeeded.|OpenAI API を選んで設定を保存し、API キーをキーチェーンに保存して今回のクラウド通信を明示的に有効化します。接続テストは課金される場合があり、成功はその通信だけを示します。
    guideDeveloper1|在 Google AI Studio 的对应项目中创建 Gemini Developer API key；使用该产品的有效密钥，不拿 Cloud Express 密钥替代。|在 Google AI Studio 的對應專案中建立 Gemini Developer API key；使用該產品的有效金鑰，不以 Cloud Express 金鑰代替。|Create a Gemini Developer API key for your project in Google AI Studio. Use a valid key for this product, not a Cloud Express key.|Google AI Studio の対象プロジェクトで Gemini Developer API キーを作成します。この製品用の有効なキーを使用し、Cloud Express のキーで代用しないでください。
    guideDeveloper2|核对官方支持地区、项目计费及速率限制。AI Studio 的项目和密钥有独立的权限要求，请使用对应服务的凭据。|核對官方支援地區、專案計費及速率限制。AI Studio 的專案和金鑰有獨立的權限要求，請使用對應服務的憑證。|Check supported regions, project billing and rate limits. AI Studio projects and keys have their own permissions; use credentials for the selected service.|公式の対象地域、プロジェクトの課金、レート制限を確認してください。AI Studio のプロジェクトとキーには個別の権限が必要です。選択したサービス用の認証情報を使用してください。
    guideDeveloper3|选择 Gemini Developer API，将对应 key 保存到钥匙串并明确启用。测试及课堂请求都使用此产品，模型由应用预设。|選擇 Gemini Developer API，將對應 key 儲存至鑰匙圈並明確啟用。測試及課堂請求均使用此產品，模型由應用程式預設。|Select Gemini Developer API, save its key to Keychain and explicitly enable requests. Tests and classroom requests use this product and the app-selected model.|Gemini Developer API を選択し、対応するキーをキーチェーンに保存して明示的に有効化します。テストと授業の通信では、この製品とアプリ指定のモデルを使用します。
    guideStandard1|在你有权限的 Google Cloud 项目中准备模型调用，填写项目 ID 和可用地区；按官方指引核对 API、计费与 IAM 模型调用权限。|在你有權限的 Google Cloud 專案中準備模型呼叫，填寫專案 ID 及可用地區；依官方指引核對 API、計費及 IAM 模型呼叫權限。|Prepare model access in a Google Cloud project you control, and enter its project ID and supported location. Follow official guidance for the API, billing and IAM inference permissions.|権限のある Google Cloud プロジェクトでモデル利用を準備し、プロジェクト ID と対応ロケーションを入力します。公式手順で API・課金・IAM の推論権限を確認してください。
    guideStandard2|由你明确提供 OAuth 短期 access token 或本人管理的服务账号 JSON。短期 token 过期需替换；服务账号必须已有对应项目权限。本程序不读取 ADC 或其他应用凭据。|由你明確提供 OAuth 短期 access token 或本人管理的服務帳號 JSON。短期 token 過期須更換；服務帳號必須已有對應專案權限。本程式不讀取 ADC 或其他應用程式憑證。|Explicitly provide a short-lived OAuth access token or a service-account JSON you manage. Replace expired short-lived tokens; the service account needs project permissions. The app does not read ADC or other apps’ credentials.|短期 OAuth アクセストークン、またはご自身で管理するサービスアカウント JSON を明示的に入力します。期限切れトークンは交換が必要で、サービスアカウントにはプロジェクト権限が必要です。ADC や他アプリの認証情報は読み取りません。
    guideStandard3|选择 Cloud Standard，保存项目和地区，再保存凭据并启用。在官方账户页面查看实际用量、地区资格及剩余额度，并核对生成内容。|選擇 Cloud Standard，儲存專案和地區，再儲存憑證並啟用。在官方帳戶頁面查看實際用量、地區資格及剩餘配額，並核對產生的內容。|Select Cloud Standard, save the project and location, then save credentials and enable requests. Check usage, regional eligibility and remaining quota on the official account pages, and review generated content.|Cloud Standard を選択し、プロジェクトとロケーション、認証情報を保存して有効化します。公式アカウント画面で使用量、対象地域、残りの利用枠を確認し、生成された内容を見直してください。
    guideExpress1|按 Google Cloud Express Mode 官方流程确认资格，使用在 Express Mode 创建的密钥；这是 Vertex／Cloud 接入，不是 AI Studio Developer key。|依 Google Cloud Express Mode 官方流程確認資格，使用在 Express Mode 建立的金鑰；這是 Vertex／Cloud 接入，不是 AI Studio Developer key。|Check eligibility through the official Google Cloud Express Mode flow and use a key created in Express Mode. This is Vertex/Cloud access, not an AI Studio Developer key.|Google Cloud Express Mode の公式手順で資格を確認し、Express Mode で作成したキーを使用します。これは Vertex／Cloud の接続であり、AI Studio Developer のキーではありません。
    guideExpress2|核对 Express 专属模型、试用期限、配额和计费条件。它与 Standard 的项目／地区端点不同；账户资格与升级方式请参阅 Google Cloud 说明。|核對 Express 專屬模型、試用期限、配額和計費條件。它與 Standard 的專案／地區端點不同；帳戶資格與升級方式請參閱 Google Cloud 說明。|Check Express-specific models, trial duration, quotas and billing. Its endpoint differs from Standard project/location endpoints; refer to Google Cloud for account eligibility and upgrade options.|Express 固有のモデル、試用期間、利用枠、課金条件を確認してください。接続先は Standard のプロジェクト／ロケーション形式とは異なります。利用資格とアップグレード方法は Google Cloud の案内を確認してください。
    guideExpress3|选择 Cloud Express，只保存其对应密钥并明确启用；此路径无需在应用填写项目或地区。请先查看测试的计费说明，再自行执行连接检查。|選擇 Cloud Express，僅儲存其對應金鑰並明確啟用；此路徑無須在應用程式填寫專案或地區。請先查看測試的計費說明，再自行執行連線檢查。|Select Cloud Express, save its key and explicitly enable requests. This path needs no project or location field in the app. Read the test’s billing notice before choosing to check the connection.|Cloud Express を選択し、対応するキーを保存して明示的に有効化します。この接続ではプロジェクトやロケーションの入力は不要です。課金の説明を確認してから、ご自身で接続テストを行ってください。
    """
    static let table: [String: [String]] = Dictionary(uniqueKeysWithValues: rows.split(separator: "\n").map { row in
        let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return (fields[0].trimmingCharacters(in: .whitespaces), Array(fields.dropFirst()))
    })
    static func string(_ key: String, language: String) -> String {
        guard let values = table[key] else { return key }
        let index = ["zh-Hans": 0, "zh-Hant": 1, "en": 2, "ja": 3][language] ?? 2
        return values[index]
    }
}
