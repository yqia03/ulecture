import Foundation

enum CloudViewText {
    static func t(_ key: String, _ language: String) -> String {
        let index = ["zh-Hans": 1, "zh-Hant": 2, "en": 3, "ja": 4][language] ?? 3
        return rows[key].map { $0[index] } ?? key
    }
    static func providerName(_ provider: CloudProvider, _ language: String) -> String {
        provider == .openAICompatible ? t("compatibleProvider", language) : provider.displayName
    }
    static func failure(_ error: CloudFailure, _ language: String) -> String { t("error." + error.rawValue, language) }
    private static let rows: [String: [String]] = Dictionary(uniqueKeysWithValues: source.split(separator: "\n").map { String($0).components(separatedBy: "|") }.filter { $0.count == 5 }.map { ($0[0], $0) })
    private static let source = """
    compatibleProvider|OpenAI 兼容 API|OpenAI 相容 API|OpenAI-compatible API|OpenAI 互換 API
    service|云服务|雲端服務|Cloud service|クラウドサービス
    aiService|AI 服务|AI 服務|AI service|AI サービス
    textTranslationService|文本翻译服务|文字翻譯服務|Text translation service|テキスト翻訳サービス
    documentTranslationService|文档翻译 / BabelDOC 服务|文件翻譯 / BabelDOC 服務|Document translation / BabelDOC service|ドキュメント翻訳 / BabelDOC サービス
    allServiceUsage|所有服务用量|所有服務用量|Usage across services|全サービスの使用量
    useAIService|使用 AI 服务的配置和 Key|使用 AI 服務的設定和 Key|Use the AI service configuration and key|AI サービスの設定とキーを使用
    sharedServiceHelp|跟随上方 AI 服务的供应商、模型、地址和 Key；关闭后恢复此翻译服务的独立配置。|跟隨上方 AI 服務的供應商、模型、網址和 Key；關閉後恢復此翻譯服務的獨立設定。|Follows the AI service provider, model, endpoint and key. Turn off to restore this translation service's independent settings.|AI サービスの提供元、モデル、エンドポイント、キーを使用します。オフにすると、この翻訳サービスの独立した設定に戻ります。
    independentServiceHelp|此翻译服务单独保存供应商、模型和 Key，不影响 AI 服务或其他翻译服务。|此翻譯服務獨立儲存供應商、模型和 Key，不影響 AI 服務或其他翻譯服務。|This translation service saves its own provider, model and key independently of the AI service and other translation services.|この翻訳サービスの提供元、モデル、キーは、AI サービスや他の翻訳サービスと別に保存されます。
    model|模型 ID|模型 ID|Model ID|モデル ID
    modelPresets|预设模型|預設模型|Model presets|モデルのプリセット
    modelHelp|可输入服务商提供的模型 ID，保存后用于新任务。|可輸入服務商提供的模型 ID，儲存後用於新任務。|Enter a model ID from your provider. Saved changes apply to new tasks.|提供元のモデル ID を入力できます。保存した変更は新規タスクに適用されます。
    baseURL|API 基础地址（如 https://api.example.com/v1）|API 基礎網址（如 https://api.example.com/v1）|API base URL (e.g. https://api.example.com/v1)|API ベース URL（例：https://api.example.com/v1）
    baseURLHelp|填写兼容 Chat Completions 的 API 基础地址，不含 /chat/completions。修改地址后需为该地址保存 Key。|填寫相容 Chat Completions 的 API 基礎網址，不含 /chat/completions。修改網址後需為該網址儲存 Key。|Enter a Chat Completions compatible API base URL, without /chat/completions. Save a key for the new endpoint after changing it.|Chat Completions 互換 API のベース URL を /chat/completions を除いて入力してください。変更後は新しい接続先のキーを保存してください。
    saveOptions|保存模型与地址|儲存模型與網址|Save model and endpoint|モデルと接続先を保存
    saveOptionsFirst|模型或地址有未保存的修改，请先点击「保存模型与地址」，再保存 Key 或测试连接。|模型或網址有未儲存的修改，請先點擊「儲存模型與網址」，再儲存 Key 或測試連線。|Save the model and endpoint changes before saving a key or testing the connection.|キーの保存や接続テストの前に、モデルと接続先の変更を保存してください。
    saveKey|保存 Key|儲存 Key|Save key|キーを保存
    saveKeyFirst|请先保存输入的 Key，再测试连接。|請先儲存輸入的 Key，再測試連線。|Save the entered key before testing the connection.|接続テストの前に、入力したキーを保存してください。
    key|API Key|API Key|API key|API キー
    save|保存|儲存|Save|保存
    remove|移除已保存的 Key|移除已儲存的 Key|Remove saved key|保存済みキーを削除
    test|测试连接（可能产生费用）|測試連線（可能產生費用）|Test connection (may incur charges)|接続テスト（料金が発生する場合があります）
    unconfigured|未配置|未設定|Not configured|未設定
    savedUnverified|已保存，未验证|已儲存，未驗證|Saved, unverified|保存済み・未検証
    checking|正在测试连接…|正在測試連線…|Testing connection…|接続テスト中…
    requestSucceeded|请求成功；地区资格以服务方为准|請求成功；地區資格以服務方為準|Request succeeded; regional eligibility depends on the provider|リクエスト成功。地域の利用資格は提供元に依存します
    failed|请求失败|請求失敗|Request failed|リクエスト失敗
    savedHelp|保存不会发送测试请求。新任务使用当前服务；已发出的请求保留原服务。|儲存不會傳送測試請求。新任務使用目前服務；已發出的請求保留原服務。|Saving sends no test request. New tasks use the current service; sent requests retain their original service.|保存時にテストリクエストは送信しません。新規タスクは現在のサービスを使用し、送信済みリクエストは元のサービスを維持します。
    legacy|旧配置已保留。请保存所选产品的 Key；旧凭据不会自动转换。|舊設定已保留。請儲存所選產品的 Key；舊憑證不會自動轉換。|Legacy settings retained. Save a key for the selected product; old credentials are not automatically converted.|旧設定は保持されています。選択した製品のキーを保存してください。旧認証情報は自動変換しません。
    guide|服务申请与费用|服務申請與費用|Setup and billing|設定と料金
    openaiGuide|在 OpenAI API 平台创建项目和 API Key，确认 API 计费后粘贴到上方。ChatGPT 订阅不包含 API 用量。可用地区以官方支持地区清单为准。|在 OpenAI API 平台建立專案和 API Key，確認 API 計費後貼至上方。ChatGPT 訂閱不包含 API 用量。可用地區以官方支援地區清單為準。|Create a project and API key on the OpenAI API platform and confirm API billing. ChatGPT subscriptions do not include API usage. See the official supported regions list for availability.|OpenAI API プラットフォームでプロジェクトと API キーを作成し、API の請求を確認してください。ChatGPT の契約に API 利用料は含まれません。利用可能な地域は公式の対応地域一覧を確認してください。
    geminiGuide|Google Gemini 使用 Google AI Studio 创建的 API Key。点击「创建 AI Studio Key」获取 Key，粘贴到上方并保存。免费额度、计费与地区可用性以 Gemini API 官方说明和账户状态为准。|Google Gemini 使用 Google AI Studio 建立的 API Key。點擊「建立 AI Studio Key」取得 Key，貼到上方並儲存。免費額度、計費與地區可用性以 Gemini API 官方說明和帳號狀態為準。|Google Gemini uses an API key created in Google AI Studio. Choose Create AI Studio key, then paste and save the key above. Free quotas, billing and regional availability depend on Gemini API policies and your account.|Google Gemini は Google AI Studio で作成した API キーを使用します。「AI Studio キーを作成」から取得し、上に貼り付けて保存してください。無料枠、料金、対応地域は Gemini API の公式案内とアカウントの状態に依存します。
    deepseekGuide|在 DeepSeek 开放平台创建 API Key，粘贴到上方并选择模型。API 用量与费用以 DeepSeek 平台为准。|在 DeepSeek 開放平台建立 API Key，貼到上方並選擇模型。API 用量與費用以 DeepSeek 平台為準。|Create an API key on the DeepSeek platform, paste it above and choose a model. Check the DeepSeek platform for API usage and billing.|DeepSeek プラットフォームで API キーを作成し、上に貼り付けてモデルを選択してください。API の使用量と料金は DeepSeek で確認できます。
    compatibleGuide|使用提供 OpenAI 兼容 Chat Completions API 的服务商。填写该服务商的 API 基础地址、模型 ID 和 Key；计费由所选服务商管理。|使用提供 OpenAI 相容 Chat Completions API 的服務商。填寫該服務商的 API 基礎網址、模型 ID 和 Key；計費由所選服務商管理。|Use a provider offering an OpenAI compatible Chat Completions API. Enter its API base URL, model ID and key. Billing is managed by that provider.|OpenAI 互換の Chat Completions API を提供するサービスを使用します。提供元の API ベース URL、モデル ID、キーを入力してください。料金は選択した提供元が管理します。
    standardGuide|这是保留的 Google Cloud Standard 配置。新配置请选择 Google AI Studio。|這是保留的 Google Cloud Standard 設定。新設定請選擇 Google AI Studio。|This is a retained Google Cloud Standard configuration. Choose Google AI Studio for new settings.|保持されている Google Cloud Standard 設定です。新しい設定には Google AI Studio を選択してください。
    expressGuide|这是保留的 Google Cloud Express 配置。新配置请选择 Google AI Studio 并保存 AI Studio Key。|這是保留的 Google Cloud Express 設定。新設定請選擇 Google AI Studio 並儲存 AI Studio Key。|This is a retained Google Cloud Express configuration. Choose Google AI Studio and save an AI Studio key for new settings.|保持されている Google Cloud Express 設定です。新しい設定には Google AI Studio を選択し、AI Studio キーを保存してください。
    createAIStudioKey|创建 AI Studio Key|建立 AI Studio Key|Create AI Studio key|AI Studio キーを作成
    official|官方文档|官方文件|Official documentation|公式ドキュメント
    billing|费用与用量|費用與用量|Billing and usage|料金と使用量
    regions|支持地区|支援地區|Supported regions|対応地域
    usageHelp|用量不是账单或硬性预算上限。取消已发送请求仍可能计费。|用量不是帳單或硬性預算上限。取消已傳送請求仍可能計費。|Usage is not a bill or a hard budget limit. Cancelling sent requests may still incur charges.|使用量は請求書や予算上限ではありません。送信済みリクエストはキャンセル後も課金される場合があります。
    accountEligibility|账户资格与期限|帳號資格與期限|Account eligibility and limits|アカウントの利用資格と期限
    title|文本翻译|文字翻譯|Text translation|テキスト翻訳
    source|原文|原文|Source|原文
    target|译文|譯文|Translation|訳文
    sourceLanguage|原文语言|原文語言|Source language|原文の言語
    targetLanguage|目标语言|目標語言|Target language|翻訳先の言語
    en|英语|英語|English|英語
    ja|日语|日語|Japanese|日本語
    zh-Hans|简体中文|簡體中文|Simplified Chinese|簡体字中国語
    zh-Hant|繁体中文|繁體中文|Traditional Chinese|繁体字中国語
    domain|翻译领域|翻譯領域|Domain|分野
    general|通用|通用|General|一般
    marketing|市场营销|市場行銷|Marketing|マーケティング
    ai|人工智能|人工智慧|Artificial intelligence|人工知能
    programming|编程|程式設計|Programming|プログラミング
    film|影视|影視|Film and television|映像
    food|食品|食品|Food|食品
    translate|开始翻译|開始翻譯|Translate|翻訳
    cancel|取消|取消|Cancel|キャンセル
    retry|继续未完成部分|繼續未完成部分|Retry unfinished parts|未完了部分を再試行
    copy|复制译文|複製譯文|Copy translation|訳文をコピー
    clear|清空|清空|Clear|クリア
    ready|等待输入|等待輸入|Ready|待機中
    running|正在翻译|正在翻譯|Translating|翻訳中
    completed|翻译完成|翻譯完成|Translation complete|翻訳完了
    cancelled|已取消|已取消|Cancelled|キャンセル済み
    interrupted|任务中断，已完成部分保留|任務中斷，已完成部分保留|Interrupted; completed parts retained|中断しました。完了した部分は保持されています
    terms|自定义术语|自訂術語|Custom terminology|カスタム用語
    scope|术语范围|術語範圍|Terminology scope|用語の適用範囲
    textScope|当前文本工具|目前文字工具|Text workspace|テキスト作業領域
    termHelp|自定义术语优先于领域习惯。任务开始时固定术语版本；修改只影响新任务。|自訂術語優先於領域習慣。任務開始時固定術語版本；修改只影響新任務。|Custom terminology overrides domain conventions. A run keeps its starting terminology version; edits affect new runs.|カスタム用語は分野の慣例より優先します。実行開始時の用語バージョンを保持し、編集は新しい実行に適用します。
    add|添加术语|新增術語|Add term|用語を追加
    edit|编辑|編輯|Edit|編集
    delete|删除|刪除|Delete|削除
    import|导入|匯入|Import|読み込み
    export|导出|匯出|Export|書き出し
    note|备注|備註|Note|注記
    enabled|启用|啟用|Enabled|有効
    conflict|相同范围与语言已有此术语，请处理冲突。|相同範圍與語言已有此術語，請處理衝突。|This term already exists in this scope and language pair. Resolve the conflict.|同じ適用範囲と言語の用語が存在します。競合を解決してください。
    keep|保留已有术语|保留現有術語|Keep existing terms|既存の用語を保持
    replace|使用导入的术语|使用匯入的術語|Use imported terms|読み込んだ用語を使用
    importHelp|CSV 列：sourceLanguage, source, targetLanguage, translation, note, enabled, scopeID。导入仅作用于当前范围。|CSV 欄：sourceLanguage, source, targetLanguage, translation, note, enabled, scopeID。匯入僅套用至目前範圍。|CSV columns: sourceLanguage, source, targetLanguage, translation, note, enabled, scopeID. Imports apply only to the current scope.|CSV 列：sourceLanguage, source, targetLanguage, translation, note, enabled, scopeID。読み込みは現在の適用範囲にのみ反映します。
    error.missingCredential|请先在设置中保存当前服务的 API Key。|請先在設定中儲存目前服務的 API Key。|Save an API key for the current service in Settings.|設定で現在のサービスの API キーを保存してください。
    error.invalidConfiguration|设置或术语格式无效，请检查输入。|設定或術語格式無效，請檢查輸入。|Invalid settings or terminology format. Check the input.|設定または用語の形式が無効です。入力を確認してください。
    error.expiredPreset|模型已停用，请更新应用。|模型已停用，請更新應用程式。|This model has retired. Update the app.|このモデルは提供を終了しました。アプリを更新してください。
    error.network|连接失败，输入与已完成结果已保留。|連線失敗，輸入與已完成結果已保留。|Connection failed. Input and completed results are retained.|接続に失敗しました。入力と完了した結果は保持されています。
    error.authentication|凭据无效或已过期，请替换当前服务的 Key。|憑證無效或已過期，請更換目前服務的 Key。|Invalid or expired credentials. Replace this service's key.|認証情報が無効または期限切れです。キーを更新してください。
    error.permission|服务拒绝访问，请核对账户权限和地区资格。|服務拒絕存取，請核對帳號權限與地區資格。|Access denied. Check account permissions and regional eligibility.|アクセスが拒否されました。アカウントの権限と地域の利用資格を確認してください。
    error.quota|额度或计费不可用，请检查服务账户。|額度或計費不可用，請檢查服務帳號。|Quota or billing unavailable. Check your provider account.|割当または請求を利用できません。提供元のアカウントを確認してください。
    error.rateLimited|服务请求受限，请稍后重试。|服務請求受限，請稍後重試。|Rate limited. Retry later.|リクエスト数が制限されています。後で再試行してください。
    error.unavailable|服务或模型暂不可用，请稍后重试。|服務或模型暫時無法使用，請稍後重試。|Service or model unavailable. Retry later.|サービスまたはモデルを利用できません。後で再試行してください。
    error.malformedResponse|响应不完整或无法对应原文，输入保留。|回應不完整或無法對應原文，輸入保留。|Response incomplete or cannot be matched to the source. Input retained.|応答が不完全、または原文と対応しません。入力は保持されています。
    error.cancelled|已取消；已发送请求仍可能计费。|已取消；已傳送請求仍可能計費。|Cancelled. Sent requests may still incur charges.|キャンセルしました。送信済みリクエストは課金される場合があります。
    error.persistence|保存失败，内存草稿保留；请检查目录后重试。|儲存失敗，記憶體草稿保留；請檢查目錄後重試。|Save failed; draft retained in memory. Check the data folder and retry.|保存失敗。下書きはメモリに保持されています。保存先を確認し再試行してください。
    error.queueFull|队列已满，原文保留。|佇列已滿，原文保留。|Queue full. Source retained.|キューが満杯です。原文は保持されています。
    error.noMaterials|请输入需要翻译的文字。|請輸入需要翻譯的文字。|Enter text to translate.|翻訳するテキストを入力してください。
    error.responseTooLarge|内容超过处理上限，原文保留。|內容超過處理上限，原文保留。|Content exceeds the processing limit. Source retained.|内容が処理上限を超えています。原文は保持されています。
    error.incompatibleCheckpoint|此任务使用旧处理版本，原文与结果保留。请点击开始翻译建立新任务。|此任務使用舊處理版本，原文與結果保留。請點擊開始翻譯建立新任務。|This task uses an older processing version. Source and results are retained. Choose Translate to start a new run.|旧処理バージョンのタスクです。原文と結果は保持されています。「翻訳」で新しい実行を開始してください。
    """
}
