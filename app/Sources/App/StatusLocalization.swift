import Foundation

/// Display translation for module diagnostics. Persisted reason codes and content remain unchanged.
/// Templates replace only explicitly declared dynamic fields; file names, paths and numbers are preserved.
enum StatusLocalizer {
    static let rows = """
    离线模型已卸载|離線模型已卸載|Offline model unloaded|オフラインモデルを解放しました
    转写保存记录无效，原文件未覆盖。|轉寫儲存記錄無效，原檔案未覆寫。|The transcript save record is invalid. Existing files were not overwritten.|文字起こしの保存記録が無効です。既存のファイルは上書きしていません。
    转写恢复副本校验失败，原文件未覆盖。|轉寫復原副本驗證失敗，原檔案未覆寫。|The transcript recovery copy could not be verified. Existing files were not overwritten.|文字起こしの復元用コピーを検証できませんでした。既存のファイルは上書きしていません。
    转写恢复副本保存失败，原文件未覆盖。|轉寫復原副本儲存失敗，原檔案未覆寫。|The transcript recovery copy could not be saved. Existing files were not overwritten.|文字起こしの復元用コピーを保存できませんでした。既存のファイルは上書きしていません。
    转写 TXT 保存未完成，请重试保存。|轉寫 TXT 儲存尚未完成，請重試儲存。|The transcript TXT save is incomplete. Retry saving.|文字起こし TXT の保存が完了していません。再試行してください。
    转写保存尚未恢复，请重试保存。|轉寫儲存尚未復原，請重試儲存。|Transcript saving has not recovered yet. Retry saving.|文字起こしの保存がまだ復旧していません。再試行してください。
    转写恢复副本的归属或资源无效。|轉寫復原副本的歸屬或資源無效。|The transcript recovery copy has an invalid owner or resource.|文字起こしの復元用コピーの所属またはリソースが無効です。
    请先设置转写保存位置再恢复会话文本副本。|請先設定轉寫儲存位置，再復原工作階段文字副本。|Choose a transcript save location before restoring session text copies.|セッションのテキストコピーを復元する前に、文字起こしの保存先を設定してください。
    会话记录已保存，但两份 TXT 尚未全部保存。请重试保存。|工作階段記錄已儲存，但兩份 TXT 尚未全部儲存。請重試儲存。|The session is saved, but both TXT files are not yet fully saved. Retry saving.|セッション記録は保存されましたが、2つの TXT ファイルの保存は完了していません。再試行してください。
    此会话尚无已保存的转写数据。|此工作階段尚無已儲存的轉寫資料。|This session has no saved transcript data yet.|このセッションにはまだ保存された文字起こしデータがありません。
    转写 TXT 路径不是普通文件，未覆盖。|轉寫 TXT 路徑不是一般檔案，未覆寫。|The transcript TXT path is not a regular file and was not overwritten.|文字起こし TXT の保存先は通常のファイルではないため、上書きしていません。
    转写 TXT 保存失败；已保留之前的文件，请重试。|轉寫 TXT 儲存失敗；已保留先前的檔案，請重試。|The transcript TXT could not be saved. The previous file is preserved; retry saving.|文字起こし TXT を保存できませんでした。以前のファイルは保持されています。再試行してください。
    无法确认转写 TXT 已保存，请重试。|無法確認轉寫 TXT 已儲存，請重試。|Could not confirm that the transcript TXT was saved. Retry saving.|文字起こし TXT の保存を確認できませんでした。再試行してください。
    转写 TXT 落盘失败，请重试保存。|轉寫 TXT 寫入磁碟失敗，請重試儲存。|Could not flush the transcript TXT to disk. Retry saving.|文字起こし TXT をディスクに書き込めませんでした。保存を再試行してください。
    此任务使用旧处理版本；已有结果保留，请新建翻译任务|此任務使用舊處理版本，原文與結果保留。請點擊開始翻譯建立新任務。|This task uses an older processing version. Source and results are retained. Choose Translate to start a new run.|旧処理バージョンのタスクです。原文と結果は保持されています。「翻訳」で新しい実行を開始してください。
    系统音频 PCM 解码失败|系統音訊 PCM 解碼失敗|System audio PCM decoding failed|システム音声の PCM デコードに失敗しました
    系统采集中断：{0}|系統擷取中斷：{0}|System capture interrupted: {0}|システム音声の収録が中断しました：{0}
    未开始采集|尚未開始擷取|Capture has not started|収録は開始していません
    系统休眠；唤醒后需手动继续|系統睡眠；喚醒後須手動繼續|System sleeping; resume manually after waking|スリープしました。復帰後に手動で再開してください
    课堂已结束；不能重新采集|課堂已結束；不能重新擷取|Classroom ended; capture cannot restart|授業は終了済みです。収録を再開できません
    音源、设备、语言或录音设置已改变；请手动继续|音源、裝置、語言或錄音設定已變更；請手動繼續|Source, device, language or recording setting changed; resume manually|入力元・デバイス・言語・録音設定を変更しました。手動で再開してください
    当前状态不能开始；请等待尾部保存，已结束课堂需新建。|目前狀態不能開始；請等待尾部儲存，已結束課堂須另行新增。|Cannot start in this state. Wait for the remaining audio to save; create a new classroom if this one has ended.|現在は開始できません。末尾の保存を待ってください。終了済みの場合は新しい授業を作成してください。
    请先准备并真实加载离线模型。|請先準備並實際載入離線模型。|Prepare and load the offline model first.|先にオフラインモデルを準備して読み込んでください。
    正在检查权限及所选音源|正在檢查權限及所選音源|Checking permissions and the selected source|権限と選択した入力元を確認中
    麦克风权限未授予；请在系统设置处理后手动继续。|麥克風權限未授予；請在系統設定處理後手動繼續。|Microphone permission is not granted. Resolve it in System Settings, then resume manually.|マイクの権限がありません。システム設定で許可した後、手動で再開してください。
    麦克风权限不可用；请在系统设置处理。|麥克風權限不可用；請在系統設定處理。|Microphone permission is unavailable. Check System Settings.|マイクの権限を利用できません。システム設定を確認してください。
    系统音频权限未授予；请处理屏幕与系统音频录制权限后重开。|系統音訊權限未授予；請處理螢幕與系統音訊錄製權限後重新開啟。|System audio permission is not granted. Check Screen & System Audio Recording permission, then reopen the app.|システム音声の権限がありません。画面とシステム音声の収録権限を確認し、アプリを開き直してください。
    保存录音已开启，但没有可写的受管目录。|已開啟儲存錄音，但沒有可寫入的受管目錄。|Recording storage is enabled, but its managed folder is not writable.|録音保存が有効ですが、管理フォルダに書き込めません。
    正在采集系统音频 · 已排除本应用音频|正在擷取系統音訊 · 已排除此應用程式音訊|Capturing system audio · This app’s audio is excluded|システム音声を収録中・本アプリの音声を除外
    正在采集所选麦克风 · 离线转写|正在擷取所選麥克風 · 離線轉寫|Capturing selected microphone · Offline transcription|選択したマイクを収録中・オフライン文字起こし
    所选输入设备失联；不会自动换设备。|所選輸入裝置已斷線；不會自動更換裝置。|The selected input device disconnected. No device was substituted.|選択した入力デバイスが切断されました。他のデバイスには自動変更しません。
    没有可用麦克风音频单元。|沒有可用的麥克風音訊單元。|No microphone audio unit is available.|利用可能なマイクの音声ユニットがありません。
    无法核验麦克风设备。|無法核驗麥克風裝置。|Could not verify the microphone device.|マイクデバイスを確認できません。
    选择麦克风失败。|選擇麥克風失敗。|Could not select the microphone.|マイクの選択に失敗しました。
    设备回读不符；未切换到默认设备。|裝置回讀不符；未切換至預設裝置。|Device verification did not match; the default device was not selected.|デバイスの確認結果が一致しません。既定のデバイスへの切り替えは行っていません。
    麦克风格式无效。|麥克風格式無效。|The microphone audio format is invalid.|マイクの音声形式が無効です。
    麦克风输入超过缓冲容量|麥克風輸入超過緩衝容量|Microphone input exceeded buffer capacity|マイク入力がバッファ容量を超えました
    麦克风 PCM 读取失败：{0}|麥克風 PCM 讀取失敗：{0}|Microphone PCM read failed: {0}|マイク PCM の読み取りに失敗しました：{0}
    系统音频没有可用显示器捕获范围。|系統音訊沒有可用的顯示器擷取範圍。|No display capture scope is available for system audio.|システム音声の収録に使用できるディスプレイ範囲がありません。
    用户已暂停；请手动继续|使用者已暫停；請手動繼續|Paused by you; resume manually|ユーザー操作により一時停止中。手動で再開してください
    系统流停止返回错误；请退出重开，不能自动继续。|停止系統串流時發生錯誤；請結束並重新開啟，不能自動繼續。|Stopping the system stream failed. Quit and reopen the app; automatic resume is disabled.|システムストリームを停止できませんでした。アプリを終了して開き直してください。自動再開はしません。
    正在完成识别尾部|正在完成辨識尾部|Finishing the remaining audio|末尾の音声を処理中
    课堂已结束；采集和回听已停止|課堂已結束；擷取及回聽已停止|Classroom ended; capture and playback stopped|授業は終了し、収録と再生を停止しました
    麦克风引擎已停止|麥克風引擎已停止|Microphone engine stopped|マイクの音声エンジンが停止しました
    麦克风权限已撤销|麥克風權限已撤銷|Microphone permission was revoked|マイクの権限が取り消されました
    所选设备已拔出；不会自动换设备|所選裝置已拔除；不會自動更換裝置|Selected device unplugged; no automatic substitution|選択したデバイスが取り外されました。自動変更はしません
    麦克风设备与选择不符|麥克風裝置與選擇不符|Microphone does not match the selected device|マイクが選択したデバイスと一致しません
    麦克风硬件或采样格式改变|麥克風硬體或取樣格式已變更|Microphone hardware or sample format changed|マイクのハードウェアまたはサンプリング形式が変更されました
    请先暂停采集，再明确回听已保存录音。|請先暫停擷取，再手動回聽已儲存的錄音。|Pause capture before choosing to play a saved recording.|収録を一時停止してから、保存済み録音を再生してください。
    录音无法播放。|錄音無法播放。|The recording could not be played.|録音を再生できません。
    录音回读帧数不符；已暂停，损坏尾部保留。|錄音回讀影格數不符；已暫停並保留損壞尾部。|Recorded frame count did not match on readback. Paused; damaged tail retained.|録音の読み戻しフレーム数が一致しません。一時停止し、破損した末尾を保持しました。
    流式语音活动模型加载失败。|串流語音活動模型載入失敗。|Streaming voice activity model failed to load.|ストリーミング音声区間検出モデルを読み込めません。
    输入缓冲超过两秒；已停止接收，请手动继续。|輸入緩衝超過兩秒；已停止接收，請手動繼續。|Input buffer exceeded two seconds. Input stopped; resume manually.|入力バッファが 2 秒を超えました。入力を停止しました。手動で再開してください。
    录音写入失败：{0}|錄音寫入失敗：{0}|Recording write failed: {0}|録音の書き込みに失敗しました：{0}
    流式语音活动检测失败|串流語音活動偵測失敗|Streaming voice activity detection failed|ストリーミング音声区間検出に失敗しました
    输入格式无法转换为离线识别 PCM。|輸入格式無法轉換為離線辨識 PCM。|Input cannot be converted to PCM for offline recognition.|入力形式をオフライン認識用の PCM に変換できません。
    PCM 重采样失败|PCM 重新取樣失敗|PCM resampling failed|PCM のリサンプリングに失敗しました
    PCM 尾部超过缓冲上限。|PCM 尾部超過緩衝上限。|The remaining PCM audio exceeds the buffer limit.|PCM 音声の末尾がバッファ上限を超えました。
    无法复制采集音频。|無法複製擷取音訊。|Could not copy the captured audio.|収録した音声をコピーできません。
    正在完成音频尾部|正在完成音訊尾部|Finishing the remaining audio|末尾の音声を処理中
    正在采集所选麦克风|正在擷取所選麥克風|Capturing the selected microphone|選択したマイクを収録中
    离线资源可用；开始本地识别时加载|離線資源可用；開始本機辨識時載入|Offline resources available; loaded when local recognition starts|オフラインリソースは利用可能です。ローカル認識の開始時に読み込みます
    采集音频缓冲格式无效。|擷取音訊緩衝格式無效。|The captured audio buffer format is invalid.|収録音声のバッファ形式が無効です。
    采集音频通道格式无效。|擷取音訊聲道格式無效。|The captured audio channel format is invalid.|収録音声のチャンネル形式が無効です。
    音频处理队列已满；请手动继续。|音訊處理佇列已滿；請手動繼續。|The audio processing queue is full; resume manually.|音声処理キューがいっぱいです。手動で再開してください。
    离线模型加载失败；没有启动云端转写。|離線模型載入失敗；沒有啟動雲端轉寫。|Offline model failed to load. Cloud transcription was not started.|オフラインモデルを読み込めません。クラウド文字起こしは開始していません。
    离线识别失败（{0}）；尾部未确认为原文。|離線辨識失敗（{0}）；尾部尚未確認為原文。|Offline recognition failed ({0}); the remaining audio was not confirmed as transcript.|オフライン認識に失敗しました（{0}）。末尾は確定文字起こしとして保存していません。
    模型文件大小不符：{0}|模型檔案大小不符：{0}|Model file size does not match: {0}|モデルファイルのサイズが一致しません：{0}
    模型 SHA-256 校验失败；原文件已保留。|模型 SHA-256 驗證失敗；原檔案已保留。|Model SHA-256 verification failed; the original file was retained.|モデルの SHA-256 検証に失敗しました。元のファイルは保持されています。
    模型下载服务器返回错误；文件未安装。|模型下載伺服器傳回錯誤；檔案尚未安裝。|Model download server returned an error; the file was not installed.|モデルのダウンロードサーバーがエラーを返しました。ファイルは未インストールです。
    离线模型尚未检查|離線模型尚未檢查|Offline model has not been checked|オフラインモデルは未確認です
    已取消；现有已验证模型仍可用|已取消；現有已驗證模型仍可用|Cancelled; the existing verified model remains available|キャンセルしました。検証済みの既存モデルは引き続き利用できます
    准备已取消；尚未就绪|準備已取消；尚未就緒|Preparation cancelled; not ready|準備をキャンセルしました。利用準備はできていません
    请先暂停课堂并等待识别完成，再准备模型。|請先暫停課堂並等待辨識完成，再準備模型。|Pause the classroom and wait for recognition to finish before preparing models.|授業を一時停止し、認識の完了を待ってからモデルを準備してください。
    正在校验 {0}|正在驗證 {0}|Verifying {0}|{0} を検証中
    正在下载 {0}|正在下載 {0}|Downloading {0}|{0} をダウンロード中
    缺少离线资源。请导入固定版本模型或点击下载（约 149 MB）；不会自动下载。|缺少離線資源。請匯入指定版本模型或按下載（約 149 MB）；不會自動下載。|Offline resources are missing. Import the required model or choose Download (about 149 MB). Download never starts automatically.|オフラインリソースがありません。指定モデルを読み込むか、ダウンロード（約 149 MB）を選択してください。自動では開始しません。
    校验并安装 {0}|驗證並安裝 {0}|Verifying and installing {0}|{0} を検証してインストール中
    正在加载离线识别模型|正在載入離線辨識模型|Loading the offline speech model|オフライン音声認識モデルを読み込み中
    费用未知；用量并非账单或硬性预算上限|費用未知；用量並非帳單或硬性預算上限|Cost unknown; usage is not a bill or enforced budget cap|料金は不明です。使用量は請求額や強制的な予算上限ではありません
    服务未配置或凭据尚未在设置中解锁|服務未設定或憑證尚未在設定中解鎖|Service is not configured, or credentials have not been unlocked in Settings|サービスが未設定、または設定で認証情報を有効化していません
    Google Cloud · Express（旧配置）|Google Cloud · Express（舊設定）|Google Cloud · Express (legacy)|Google Cloud · Express（旧設定）
    OpenAI 兼容 API|OpenAI 相容 API|OpenAI-compatible API|OpenAI 互換 API
    服务、模型或 API 地址设置无效|服務、模型或 API 位址設定無效|Invalid service, model or API URL settings|サービス、モデル、API URL の設定が無効です
    服务项目或区域设置无效|服務專案或區域設定無效|Service project or region is invalid|サービスのプロジェクトまたはリージョン設定が無効です
    模型预设已到复核期限，请更新应用预设后重试|模型預設已到覆核期限，請更新應用程式預設後重試|The model preset is due for review. Update the app preset before retrying|モデル設定の再確認期限を過ぎています。アプリの設定を更新してから再試行してください
    连接失败，原文保留；有限重试后需手动处理|連線失敗，原文保留；有限重試後須手動處理|Connection failed; transcript retained. Limited retries are followed by manual recovery|接続に失敗しました。原文は保持されています。回数制限付きの再試行後は手動対応が必要です
    凭据无效或已过期，请在设置中替换|憑證無效或已過期，請在設定中更換|Credentials are invalid or expired. Replace them in Settings|認証情報が無効または期限切れです。設定で更新してください
    服务拒绝访问，请核对权限及地区资格|服務拒絕存取，請核對權限及地區資格|Access denied. Check permissions and regional eligibility|アクセスが拒否されました。権限と対象地域の条件を確認してください
    额度或计费不可用，请查看服务账户|配額或計費不可用，請查看服務帳號|Quota or billing is unavailable. Check the service account|利用枠または課金を利用できません。サービスのアカウントを確認してください
    请求受限，正在等待有限重试|請求受限，正在等待有限重試|Rate limited; waiting for a bounded retry|リクエスト制限中です。回数制限付きの再試行を待っています
    当前服务或模型暂不可用|目前服務或模型暫時無法使用|The current service or model is temporarily unavailable|現在のサービスまたはモデルは一時的に利用できません
    响应缺失、被截断或无法与来源可靠对应|回應缺失、被截斷或無法與來源可靠對應|Response missing, truncated or not reliably matched to its source|応答が欠落・切り詰められたか、出典との対応を確認できません
    已取消；已发送的请求仍可能计费|已取消；已傳送的請求仍可能計費|Cancelled; requests already sent may still incur charges|キャンセルしました。送信済みのリクエストは課金される場合があります
    结果未能保存；已停止派发，保留内存草稿供恢复|結果未能儲存；已停止派送，記憶體草稿保留供復原|Results could not be saved. Dispatch stopped; in-memory drafts retained for recovery|結果を保存できませんでした。送信を停止し、復元用の下書きをメモリに保持しています
    待翻译队列已达上限；原文保留，处理后可补译|待翻譯佇列已達上限；原文保留，處理後可補譯|Translation queue is full. Transcript retained; catch up after resolving the queue|翻訳待ちが上限に達しました。原文は保持されています。待機分の処理後に補完できます
    没有可用的已保存课堂文字资料|沒有可用的已儲存課堂文字資料|No saved classroom text is available|利用できる保存済みの授業テキストがありません
    材料或响应超出本次处理上限，未处理范围已保留|資料或回應超出本次處理上限，未處理範圍已保留|Materials or response exceed this run's limit. Unprocessed coverage is retained|資料または応答が今回の処理上限を超えました。未処理の範囲は保持されています
    关闭|關閉|Off|オフ
    需要正在进行的课堂及可用普通话声音；可在系统设置 → 辅助功能 → 朗读内容准备声音|需要進行中的課堂及可用普通話聲音；可在系統設定 → 輔助使用 → 朗讀內容準備聲音|An active classroom and a Mandarin voice are required. Prepare voices in System Settings → Accessibility → Spoken Content|進行中の授業と普通話の音声が必要です。システム設定 → アクセシビリティ → 読み上げコンテンツで音声を準備してください
    仅朗读开启后的新译文|僅朗讀開啟後的新譯文|Only new translations after enabling speech are read aloud|有効化後の新しい翻訳のみ読み上げます
    正在朗读已保存译文|正在朗讀已儲存的譯文|Reading saved translation aloud|保存済みの翻訳を読み上げ中
    资料库目录不存在。|資料庫目錄不存在。|The library folder does not exist.|ライブラリフォルダが存在しません。
    请选择资料库文件夹。|請選擇資料庫資料夾。|Choose a library folder.|ライブラリフォルダを選択してください。
    此目录没有资料库。|此目錄沒有資料庫。|This folder does not contain a library.|このフォルダにライブラリはありません。
    资料库不可写或被另一个应用实例占用。|資料庫無法寫入或由另一個應用程式執行個體佔用。|The library is not writable or another app instance is using it.|ライブラリに書き込めないか、別のアプリインスタンスが使用中です。
    资料库已按只读方式打开：位置不可写或另一个应用实例正在使用。|資料庫已以唯讀方式開啟：位置無法寫入或另一個應用程式執行個體正在使用。|Library opened read-only: the location is not writable or another app instance is using it.|読み取り専用で開きました。保存先に書き込めないか、別のアプリインスタンスが使用中です。
    资料库格式 {0} 不受支持；请使用更新版本。原资料未修改。|不支援資料庫格式 {0}；請使用較新版本。原資料未修改。|Library format {0} is unsupported. Use a newer app version. Original data was not modified.|ライブラリ形式 {0} は未対応です。新しいアプリを使用してください。元のデータは変更していません。
    未知资料库格式；原资料未修改。|未知資料庫格式；原資料未修改。|Unknown library format; original data was not modified.|不明なライブラリ形式です。元のデータは変更していません。
    资料库位置不可写，已只读打开；编辑不会显示为已保存。|資料庫位置無法寫入，已以唯讀方式開啟；編輯不會顯示為已儲存。|Library location is not writable. Opened read-only; edits will not be marked saved.|保存先に書き込めないため読み取り専用で開きました。編集を保存済みとは表示しません。
    此资料库尚未初始化，无法只读打开。|此資料庫尚未初始化，無法以唯讀方式開啟。|This library is not initialized and cannot be opened read-only.|未初期化のライブラリは読み取り専用で開けません。
    资料库身份损坏，请保留原目录。|資料庫識別資訊損壞，請保留原目錄。|Library identity is damaged. Keep the original folder.|ライブラリの識別情報が破損しています。元のフォルダを保持してください。
    资料库完整性检查失败；请保留原目录。|資料庫完整性檢查失敗；請保留原目錄。|Library integrity check failed. Keep the original folder.|ライブラリの整合性検査に失敗しました。元のフォルダを保持してください。
    资料库以只读方式打开，内容尚未保存。|資料庫以唯讀方式開啟，內容尚未儲存。|Library is read-only; content has not been saved.|ライブラリは読み取り専用です。内容は保存されていません。
    资料库目录失联或不可写，内容尚未保存。|資料庫目錄已斷線或無法寫入，內容尚未儲存。|Library folder is disconnected or not writable; content has not been saved.|ライブラリフォルダに接続または書き込みできません。内容は保存されていません。
    资料库目录没有写入权限，内容尚未保存。|資料庫目錄沒有寫入權限，內容尚未儲存。|Library folder lacks write permission; content has not been saved.|ライブラリフォルダへの書き込み権限がありません。内容は未保存です。
    资料库数据库不可写，内容尚未保存。|資料庫檔案無法寫入，內容尚未儲存。|Library database is not writable; content has not been saved.|ライブラリのデータベースに書き込めません。内容は未保存です。
    资料库数据库没有写入权限，内容尚未保存。|資料庫檔案沒有寫入權限，內容尚未儲存。|Library database lacks write permission; content has not been saved.|ライブラリのデータベースへの書き込み権限がありません。内容は未保存です。
    请通过导入 PDF 建立受管附件。|請透過匯入 PDF 建立受管附件。|Use Import PDF to create a managed attachment.|PDF の読み込みから管理対象の添付ファイルを作成してください。
    课堂附件和笔记随课堂整理，不能脱离课堂。|課堂附件及筆記隨課堂整理，不能脫離課堂。|Classroom attachments and notes stay with their classroom.|授業の添付ファイルとノートは授業と一緒に整理します。授業から切り離せません。
    不能移入自身或下级文件夹。|不能移入本身或下層資料夾。|Cannot move an item into itself or a descendant folder.|自身または配下のフォルダには移動できません。
    移动不能改变课堂归属；请在课堂中导入 PDF 或新建课堂笔记。|移動不能改變課堂歸屬；請在課堂中匯入 PDF 或新增課堂筆記。|Moving cannot change classroom ownership. Import a PDF or create a note inside the classroom.|移動で授業の所属は変更できません。授業内で PDF を読み込むかノートを作成してください。
    课堂必须保留所属课程；不能跨课程移动包含课堂的内容。|課堂必須保留所屬課程；不能跨課程移動包含課堂的內容。|Classrooms must retain their course. Items containing classrooms cannot move across courses.|授業は元のコースに所属する必要があります。授業を含む項目は別コースへ移動できません。
    课堂附件和笔记随课堂删除与恢复。|課堂附件及筆記隨課堂刪除與復原。|Classroom attachments and notes are deleted and restored with the classroom.|授業の添付ファイルとノートは授業と一緒に削除・復元します。
    请先结束未完成的课堂，再删除这些资料。|請先結束未完成的課堂，再刪除這些資料。|End unfinished classrooms before deleting these materials.|未終了の授業を終了してから資料を削除してください。
    保存对象不属于此资料库。|儲存對象不屬於此資料庫。|The item being saved does not belong to this library.|保存対象の項目はこのライブラリに属していません。
    课堂配置无效。|課堂設定無效。|Classroom configuration is invalid.|授業の設定が無効です。
    已结束课堂不能重新开始；请新建课堂。|已結束課堂不能重新開始；請新增課堂。|Ended classrooms cannot restart. Create a new classroom.|終了済みの授業は再開できません。新しい授業を作成してください。
    确认原文的内容或时间范围无效。|確認原文的內容或時間範圍無效。|Confirmed transcript content or timing is invalid.|確定した原文の内容または時間範囲が無効です。
    原文身份不能跨课堂复用。|原文識別資訊不能跨課堂重複使用。|Transcript identities cannot be reused across classrooms.|原文の識別子を別の授業で再利用できません。
    同一原文修订出现冲突。|同一原文修訂出現衝突。|Conflicting content for the same transcript revision.|同一の原文リビジョンに競合する内容があります。
    此条目不是笔记。|此項目不是筆記。|This item is not a note.|この項目はノートではありません。
    首版请先将文件导出为 PDF。|首版請先將檔案匯出為 PDF。|Export the file to PDF before importing in this version.|このバージョンでは、先にファイルを PDF に変換してください。
    无法读取此 PDF，文件可能损坏或受密码保护。|無法讀取此 PDF，檔案可能損壞或受密碼保護。|Cannot read this PDF. It may be damaged or password-protected.|PDF を読み込めません。破損またはパスワード保護の可能性があります。
    受管 PDF 回读失败。|受管 PDF 回讀失敗。|Managed PDF could not be read back.|管理対象の PDF を読み戻せません。
    附件记录不存在。|附件記錄不存在。|Attachment record does not exist.|添付ファイルの記録がありません。
    受管附件缺失，请从完整备份恢复。|受管附件遺失，請從完整備份復原。|Managed attachment is missing. Restore it from a complete backup.|管理対象の添付ファイルがありません。完全バックアップから復元してください。
    录音附件或时间范围无效。|錄音附件或時間範圍無效。|Recording attachment or time range is invalid.|録音の添付ファイルまたは時間範囲が無効です。
    录音时长与课堂映射不符，尚未登记为可回听。|錄音時長與課堂對應不符，尚未登記為可回聽。|Recording duration does not match the classroom timeline; playback has not been registered.|録音時間が授業の時間軸と一致しません。再生可能な録音として登録していません。
    无法验证录音。|無法驗證錄音。|Cannot verify the recording.|録音を検証できません。
    录音尾部不完整，尚未登记为可回听。|錄音尾部不完整，尚未登記為可回聽。|Recording tail is incomplete; playback has not been registered.|録音の末尾が不完全です。再生可能な録音として登録していません。
    间断时间无效。|中斷時間無效。|Gap timing is invalid.|中断区間の時間が無効です。
    此记录类型不能保存在课堂资料库。|此記錄類型不能儲存至課堂資料庫。|This record type cannot be stored in the classroom library.|この記録形式は授業ライブラリに保存できません。
    附件路径不安全。|附件路徑不安全。|Unsafe attachment path.|添付ファイルのパスが安全ではありません。
    附件路径或符号链接不安全。|附件路徑或符號連結不安全。|Unsafe attachment path or symbolic link.|添付ファイルのパスまたはシンボリックリンクが安全ではありません。
    名称不能为空，且不得超过 500 个字符。|名稱不能留空，且不得超過 500 個字元。|Enter a name of 1–500 characters.|名前は 1～500 文字で入力してください。
    资料不存在或已删除。|資料不存在或已刪除。|The item does not exist or was deleted.|資料が存在しないか、削除されています。
    课程只能位于工作空间顶层。|課程只能位於工作空間頂層。|Courses must be at the workspace root.|コースはワークスペースの最上位に配置してください。
    请先选择课程，再新建课堂。|請先選擇課程，再新增課堂。|Select a course before creating a classroom.|コースを選択してから授業を作成してください。
    此条目不能包含资料。|此項目不能包含資料。|This item cannot contain other materials.|この項目の中に資料は配置できません。
    课堂中仅能添加 PDF 和课堂笔记。|課堂中只能新增 PDF 及課堂筆記。|Only PDFs and classroom notes can be added inside a classroom.|授業内に追加できるのは PDF と授業ノートのみです。
    课堂必须属于课程。|課堂必須屬於課程。|A classroom must belong to a course.|授業はコースに属する必要があります。
    不支持此附件类型。|不支援此附件類型。|This attachment type is not supported.|この添付ファイル形式には対応していません。
    请选择普通附件文件。|請選擇一般附件檔案。|Select a regular attachment file.|通常の添付ファイルを選択してください。
    附件为空，尚未导入。|附件為空，尚未匯入。|Attachment is empty and was not imported.|添付ファイルが空のため読み込んでいません。
    无法确认附件目录已保存。|無法確認附件目錄已儲存。|Could not confirm attachment folder persistence.|添付ファイルフォルダの保存を確認できません。
    附件目录落盘失败，内容尚未保存。|附件目錄寫入磁碟失敗，內容尚未儲存。|Attachment folder could not be committed to disk; content has not been saved.|添付ファイルフォルダをディスクに確定できません。内容は未保存です。
    应用中断；最后未确认的音频尾部可能未保存。重开不会自动采集或播报。|應用程式中斷；最後未確認的音訊尾部可能未儲存。重新開啟不會自動擷取或播報。|App interrupted; the last unconfirmed audio may be unsaved. Reopening never starts capture or speech automatically.|アプリが中断しました。未確定の音声末尾は未保存の可能性があります。再起動時に収録や読み上げは自動開始しません。
    已恢复中断课堂的已提交资料；未确认音频尾部可能缺失。|已復原中斷課堂的已提交資料；未確認音訊尾部可能遺失。|Committed classroom data recovered; the unconfirmed audio tail may be missing.|確定保存済みの授業資料を復元しました。未確定の音声末尾は欠落している可能性があります。
    附件缺失或大小不符：{0}。请使用完整备份恢复。|附件遺失或大小不符：{0}。請使用完整備份復原。|Attachment missing or size mismatch: {0}. Restore from a complete backup.|添付ファイルの欠落またはサイズ不一致：{0}。完全バックアップから復元してください。
    附件无法读取：{0}。原记录已保留。|附件無法讀取：{0}。原記錄已保留。|Cannot read attachment: {0}. Original record retained.|添付ファイルを読み込めません：{0}。元の記録は保持しています。
    发现 {0} 个未完成导入文件，未计为已保存；保留在 staging 供诊断。|發現 {0} 個未完成匯入檔案，未計為已儲存；保留在 staging 供診斷。|Found {0} unfinished imports, not marked saved; retained in staging for diagnosis.|未完了の読み込みが {0} 件あります。保存済みにはせず、診断用に staging に保持しています。
    发现 {0} 个未登记附件（可能来自中断导入）；保留文件，不计为成功导入。|發現 {0} 個未登記附件（可能來自中斷匯入）；保留檔案，不計為成功匯入。|Found {0} unregistered attachments, possibly from interrupted imports. Files retained; not marked imported.|未登録の添付ファイルが {0} 件あります。読み込み中断の可能性があります。ファイルを保持し、読み込み済みとはしません。
    目标已存在，请使用新名称，避免覆盖备份。|目標已存在，請使用新名稱，避免覆寫備份。|Destination exists. Choose a new name to avoid overwriting a backup.|保存先が存在します。バックアップを上書きしないよう別名を選択してください。
    附件校验失败，备份未完成：{0}|附件驗證失敗，備份尚未完成：{0}|Attachment verification failed; backup incomplete: {0}|添付ファイルの検証に失敗しました。バックアップは未完了です：{0}
    备份附件回读失败。|備份附件回讀失敗。|Backup attachment readback failed.|バックアップの添付ファイルを読み戻せません。
    备份清单过大，无法安全恢复。|備份清單過大，無法安全復原。|Backup manifest is too large to restore safely.|バックアップ一覧が大きすぎるため、安全に復元できません。
    备份清单损坏或不完整；现有资料未修改。|備份清單損壞或不完整；現有資料未修改。|Backup manifest is damaged or incomplete; existing data was not modified.|バックアップ一覧が破損または不完全です。既存データは変更していません。
    备份包含循环层级。|備份包含循環階層。|Backup contains a circular hierarchy.|バックアップの階層が循環しています。
    恢复附件回读校验失败。|復原附件回讀驗證失敗。|Restored attachment failed readback verification.|復元した添付ファイルの読み戻し検証に失敗しました。
    导出位置已存在，请选择新文件夹。|匯出位置已存在，請選擇新資料夾。|Export destination exists. Choose a new folder.|書き出し先が存在します。新しいフォルダを選択してください。
    所选导出资料不存在或已删除。|所選匯出資料不存在或已刪除。|Selected export item is missing or deleted.|書き出す資料が存在しないか、削除されています。
    不支持此备份格式或备份规模。|不支援此備份格式或備份規模。|Backup format or size is unsupported.|このバックアップの形式または規模には対応していません。
    备份包含重复或无效身份。|備份包含重複或無效的識別資訊。|Backup contains duplicate or invalid identities.|バックアップに重複または無効な識別子があります。
    备份组织关系缺失。|備份組織關係缺失。|Backup organizational relationships are missing.|バックアップの構成上の関連が欠けています。
    备份课程层级无效。|備份課程階層無效。|Backup course hierarchy is invalid.|バックアップのコース階層が無効です。
    备份课堂缺少所属课程。|備份課堂缺少所屬課程。|A backed-up classroom is missing its course.|バックアップ内の授業に所属コースがありません。
    备份层级不合法。|備份階層不合法。|Backup hierarchy is invalid.|バックアップの階層が無効です。
    备份课程关系不一致。|備份課程關係不一致。|Backup course relationships are inconsistent.|バックアップのコース関連が一致しません。
    备份课堂附件归属不一致。|備份課堂附件歸屬不一致。|Backup classroom attachment ownership is inconsistent.|バックアップ内の授業添付ファイルの所属が一致しません。
    备份附件身份重复。|備份附件識別資訊重複。|Backup attachment identities are duplicated.|バックアップの添付ファイル識別子が重複しています。
    备份附件清单无效。|備份附件清單無效。|Backup attachment manifest is invalid.|バックアップの添付ファイル一覧が無効です。
    备份附件不完整或校验失败：{0}|備份附件不完整或驗證失敗：{0}|Backup attachment is incomplete or failed verification: {0}|バックアップの添付ファイルが不完全、または検証に失敗しました：{0}
    PDF 依赖不完整。|PDF 相依項目不完整。|PDF dependencies are incomplete.|PDF の依存データが不足しています。
    备份记录重复或归属缺失。|備份記錄重複或歸屬缺失。|Backup records are duplicated or lack ownership.|バックアップの記録が重複しているか、所属が欠けています。
    备份课堂记录无效。|備份課堂記錄無效。|Backup classroom record is invalid.|バックアップの授業記録が無効です。
    备份原文时间或归属无效。|備份原文時間或歸屬無效。|Backup transcript timing or ownership is invalid.|バックアップの原文の時間または所属が無効です。
    备份笔记引用不完整。|備份筆記引用不完整。|Backup note references are incomplete.|バックアップのノート参照が不完全です。
    备份 PDF 页码引用无效。|備份 PDF 頁碼引用無效。|Backup PDF page references are invalid.|バックアップの PDF ページ参照が無効です。
    备份录音映射不完整。|備份錄音對應不完整。|Backup recording mapping is incomplete.|バックアップの録音と時間軸の対応が不完全です。
    备份含符号链接，已拒绝。|備份包含符號連結，已拒絕。|Backup rejected because it contains symbolic links.|シンボリックリンクを含むため、バックアップを拒否しました。
    备份含可执行内容，已拒绝。|備份包含可執行內容，已拒絕。|Backup rejected because it contains executable content.|実行可能な内容を含むため、バックアップを拒否しました。
    云任务课堂归属无效。|雲端工作課堂歸屬無效。|Cloud task classroom ownership is invalid.|クラウド処理の授業所属が無効です。
    翻译任务的原文引用缺失。|翻譯工作的原文引用缺失。|Translation task is missing its transcript reference.|翻訳処理の原文参照がありません。
    备份译文与原文或派发版本不一致。|備份譯文與原文或派送版本不一致。|Backed-up translation does not match its transcript or dispatch version.|バックアップの翻訳が原文または送信バージョンと一致しません。
    已完成翻译缺少译文。|已完成翻譯缺少譯文。|A completed translation is missing its result.|完了した翻訳に結果がありません。
    总结来源快照无效。|總結來源快照無效。|Summary source snapshot is invalid.|要約の出典スナップショットが無効です。
    总结来源身份或版本无效。|總結來源識別資訊或版本無效。|Summary source identity or version is invalid.|要約の出典識別子またはバージョンが無効です。
    总结 PDF 来源不存在或文字版本不符。|總結 PDF 來源不存在或文字版本不符。|Summary PDF source is missing or its text version differs.|要約の PDF 出典が存在しないか、テキストのバージョンが異なります。
    总结笔记固定版本缺失。|總結筆記固定版本缺失。|The fixed note revision used by the summary is missing.|要約に使用した固定ノートリビジョンがありません。
    总结原文来源或时间无效。|總結原文來源或時間無效。|Summary transcript source or timing is invalid.|要約の原文出典または時間が無効です。
    未知总结来源类型。|未知總結來源類型。|Unknown summary source type.|不明な要約出典の種類です。
    总结引用指向快照外来源。|總結引用指向快照外來源。|Summary citation points outside its snapshot.|要約の引用先がスナップショットの範囲外です。
    总结分块完成清单不一致。|總結分塊完成清單不一致。|Summary chunk completion records are inconsistent.|要約の分割処理の完了記録が一致しません。
    总结分块覆盖超出来源范围。|總結分塊涵蓋範圍超出來源。|Summary chunk coverage exceeds its source.|要約の分割処理範囲が出典を超えています。
    无法打开资料库|無法開啟資料庫|Cannot open library|ライブラリを開けません
    磁盘空间不足；内容尚未保存。|磁碟空間不足；內容尚未儲存。|Disk space is insufficient; content has not been saved.|ディスクの空き容量が不足しています。内容は未保存です。
    资料库不可写；内容尚未保存。|資料庫無法寫入；內容尚未儲存。|Library is not writable; content has not been saved.|ライブラリに書き込めません。内容は未保存です。
    资料库目录失联或发生读写错误；内容尚未保存。|資料庫目錄已斷線或發生讀寫錯誤；內容尚未儲存。|Library folder disconnected or an I/O error occurred; content has not been saved.|ライブラリフォルダの切断または入出力エラーが発生しました。内容は未保存です。
    资料库损坏。请保留原目录并从备份恢复到新目录。|資料庫損壞。請保留原目錄並從備份復原至新目錄。|Library is damaged. Keep the original folder and restore a backup to a new folder.|ライブラリが破損しています。元のフォルダを保持し、新しいフォルダにバックアップを復元してください。
    资料库正由其他操作占用；请重试。|資料庫正由其他操作佔用；請重試。|Library is busy with another operation. Retry shortly.|別の操作がライブラリを使用中です。再試行してください。
    资料库操作失败（SQLite {0}）。|資料庫操作失敗（SQLite {0}）。|Library operation failed (SQLite {0}).|ライブラリ操作に失敗しました（SQLite {0}）。
    仅提取文字；图片、扫描内容和图表未分析。|僅擷取文字；圖片、掃描內容和圖表尚未分析。|Text extraction only; images, scans and charts are not analyzed.|テキストのみ抽出します。画像・スキャン・図表は未解析です。
    包含所选范围文字和受管附件；不含模型、账户凭据或原文件路径。恢复后云请求需重新由用户确认服务。|包含所選範圍文字及受管附件；不含模型、帳號憑證或原檔案路徑。復原後雲端請求須由使用者重新確認服務。|Includes selected text and managed attachments, without models, credentials or original file paths. After restoring, confirm the service again before cloud requests.|選択範囲のテキストと管理対象の添付ファイルを含みます。モデル・認証情報・元のファイルパスは含みません。復元後のクラウド通信にはサービスの再確認が必要です。
    现有已验证的内存模型仍可用；磁盘资源准备失败：{0}|現有已驗證的記憶體模型仍可用；磁碟資源準備失敗：{0}|The verified model in memory remains available; preparing resources on disk failed: {0}|メモリ内の検証済みモデルは引き続き利用できます。ディスク上のリソースの準備に失敗しました：{0}
    缓存模型损坏且没有通过校验的随包副本；请导入固定版本或显式下载。坏文件已保留。|快取模型損壞且沒有通過驗證的隨附副本；請匯入指定版本或手動下載。損壞檔案已保留。|Cached model is damaged and no verified bundled copy is available. Import the required version or explicitly download it. Damaged files were retained.|キャッシュモデルが破損し、検証済みの同梱コピーもありません。指定バージョンを読み込むか、手動でダウンロードしてください。破損ファイルは保持されています。
    SQLite: {0}|SQLite：{0}|SQLite: {0}|SQLite：{0}
    Library closed|資料庫已關閉|Library closed|ライブラリは閉じられました
    Library unavailable|資料庫無法使用|Library unavailable|ライブラリを利用できません
    AI 来源快照无效。|AI 來源快照無效。|The AI source snapshot is invalid.|AI の出典スナップショットが無効です。
    AI 来源快照缺失。|AI 來源快照缺失。|The AI source snapshot is missing.|AI の出典スナップショットがありません。
    AI 来源身份或固定文字缺失。|AI 來源身份或固定文字缺失。|The AI source identity or fixed text is missing.|AI の出典識別子または固定テキストがありません。
    PDF 损坏、加密或没有可读取页面。|PDF 損壞、加密或沒有可讀取頁面。|The PDF is damaged, encrypted, or has no readable pages.|PDF が破損・暗号化されているか、読み取れるページがありません。
    不导入符号链接。请选择原文件。|不導入符號鏈接。請選擇原文件。|Symbolic links cannot be imported. Select the original file.|シンボリックリンクは読み込めません。元のファイルを選択してください。
    不能选择已挂载课程或其上级/下级文件夹。|不能選擇已掛載課程或其上級/下級文件夾。|Select a folder outside mounted courses and their parent or child folders.|接続済みコースと、その親・子フォルダ以外を選択してください。
    中断恢复的目标已被修改，已停止且未覆盖。请保留它并选择新的恢复位置。|中斷恢復的目標已被修改，已停止且未覆蓋。請保留它並選擇新的恢復位置。|The interrupted restore destination has changed. Stopped without overwriting it. Keep it and select a new destination.|中断した復元先が変更されています。上書きせず停止しました。そのまま保持し、新しい復元先を選択してください。
    会话元数据损坏。|會話元數據損壞。|Session metadata is damaged.|セッションのメタデータが破損しています。
    会话包含无效或其他所有者记录。|會話包含無效或其他所有者記錄。|The session contains invalid records or records owned by another session.|無効な記録または別セッションに属する記録が含まれています。
    会话数据库不是普通文件。|會話數據庫不是普通文件。|The session database is not a regular file.|セッションのデータベースが通常のファイルではありません。
    会话数据库尚未完成首次保存。|會話數據庫尚未完成首次保存。|The session database has not completed its first save.|セッションのデータベースの初回保存が完了していません。
    会话数据库已在外部删除或移动，内容尚未保存。|會話數據庫已在外部刪除或移動，內容尚未保存。|The session database was moved or deleted outside the app. Content is not saved.|セッションのデータベースがアプリ外で移動または削除されました。内容は未保存です。
    会话数据库版本或完整性检查未通过。|會話數據庫版本或完整性檢查未通過。|The session database failed the version or integrity check.|セッションのデータベースのバージョンまたは整合性を確認できません。
    会话数据库的稳定标识不匹配，未改写。|會話數據庫的穩定標識不匹配，未改寫。|The session database identity does not match. Nothing was rewritten.|セッションのデータベースの識別子が一致しません。書き換えていません。
    会话有尚未协调的保存结果，备份未发布。请先重试保存。|會話有尚未協調的保存結果，備份未發佈。請先重試保存。|Session saves have not been reconciled. The backup was not published. Retry saving first.|セッションの保存結果が未調整です。バックアップは未公開です。先に保存を再試行してください。
    会话标识与现有非课堂项目冲突。|會話標識與現有非課堂項目衝突。|The session identity conflicts with an existing non-classroom item.|セッションの識別子が既存の授業以外の項目と競合しています。
    会话目录不是普通目录。|會話目錄不是普通目錄。|The session folder is not a regular directory.|セッションの保存先が通常のフォルダではありません。
    会话记录的所有者不匹配。|會話記錄的所有者不匹配。|The session record owner does not match.|セッション記録の所属が一致しません。
    会话资料引用缺失。|會話資料引用缺失。|A session material reference is missing.|セッション資料への参照がありません。
    会话路径与稳定标识不一致。|會話路徑與穩定標識不一致。|The session path does not match its stable identity.|セッションのパスと固定識別子が一致しません。
    会话附件元数据无效。|會話附件元數據無效。|Session attachment metadata is invalid.|セッション添付ファイルのメタデータが無効です。
    会话附件路径标识无效。|會話附件路徑標識無效。|The session attachment path identity is invalid.|セッション添付ファイルのパス識別子が無効です。
    关联目标不是课堂。|關聯目標不是課堂。|The link target is not a classroom.|関連付け先が授業ではありません。
    原位置已有同名内容；请先移动该内容再恢复。|原位置已有同名內容；請先移動該內容再恢復。|The original location already contains an item with this name. Move it before restoring.|元の場所に同名の項目があります。その項目を移動してから復元してください。
    原课程标识与现有其他项目冲突。|原課程標識與現有其他項目衝突。|The original course identity conflicts with another existing item.|元のコース識別子が既存の別項目と競合しています。
    另一个音频会话正在启动、采集或停止；请先暂停并等待保存完成。|另一個音頻會話正在啓動、採集或停止；請先暫停並等待保存完成。|Another audio session is starting, capturing, or stopping. Pause it and wait for saving to finish.|別の音声セッションが開始・収録・停止処理中です。一時停止し、保存の完了を待ってください。
    名称不能为空、以点开头或包含路径分隔符，长度应小于 220 字节。|名稱不能為空、以點開頭或包含路徑分隔符，長度應小於 220 字節。|Names must not be empty, start with a dot, or contain path separators, and must be under 220 bytes.|名前は空欄・ドット始まり・パス区切り文字を使用できません。220 バイト未満にしてください。
    备份对象不存在。|備份對象不存在。|The backup item does not exist.|バックアップ対象の項目が存在しません。
    备份引用缺失。|備份引用缺失。|A backup reference is missing.|バックアップの参照が欠落しています。
    备份文档或版本依赖不完整。|備份文檔或版本依賴不完整。|Backup document or version dependencies are incomplete.|バックアップの文書またはバージョンの依存データが不完全です。
    备份期间文件发生变化，保留暂存副本，未显示成功。|備份期間文件發生變化，保留暫存副本，未顯示成功。|A file changed during backup. The staged copy was retained; the backup is not marked successful.|バックアップ中にファイルが変更されました。一時コピーを保持し、成功とは記録していません。
    备份期间资料有新版本，请重试。|備份期間資料有新版本，請重試。|Materials changed during backup. Please retry.|バックアップ中に資料が更新されました。再試行してください。
    备份格式不支持或规模无效。|備份格式不支持或規模無效。|The backup format is unsupported or its size is invalid.|バックアップ形式が未対応か、規模が無効です。
    备份清单过大。|備份清單過大。|The backup manifest is too large.|バックアップの一覧データが大きすぎます。
    备份记录包含本机位置、重复或缺失归属。|備份記錄包含本機位置、重復或缺失歸屬。|Backup records contain local locations, duplicates, or missing ownership.|バックアップ記録にローカル保存先、重複、または所属の欠落があります。
    备份资源校验失败，现有资料未修改。|備份資源校驗失敗，現有資料未修改。|Backup resource verification failed. Existing materials were not changed.|バックアップリソースの検証に失敗しました。既存の資料は変更していません。
    备份资源重复或清单为空。|備份資源重復或清單為空。|Backup resources are duplicated or the manifest is empty.|バックアップリソースが重複しているか、一覧が空です。
    备份身份无效或重复。|備份身份無效或重復。|Backup identities are invalid or duplicated.|バックアップの識別子が無効または重複しています。
    备份附件依赖不完整。|備份附件依賴不完整。|Backup attachment dependencies are incomplete.|バックアップの添付ファイルの依存データが不完全です。
    复制时原文件发生变化；导入未提交。|複製時原文件發生變化；導入未提交。|The original file changed during copying. Import was not committed.|コピー中に元のファイルが変更されました。読み込みは確定していません。
    完整备份恢复尚未提交，请重试原恢复任务。|完整備份恢復尚未提交，請重試原恢復任務。|The complete backup restore has not been committed. Retry the original restore task.|バックアップ全体の復元が未確定です。元の復元処理を再試行してください。
    已有未完成迁移，请继续原目标以保留恢复记录。|已有未完成遷移，請繼續原目標以保留恢復記錄。|A migration is unfinished. Continue with its original destination to preserve recovery records.|未完了の移行があります。復旧記録を保持するため、元の移行先で続行してください。
    已有迁移快照，未覆盖。|已有遷移快照，未覆蓋。|A migration snapshot already exists. It was not overwritten.|移行スナップショットが既にあります。上書きしていません。
    录音副本校验失败，原件保留。|錄音副本校驗失敗，原件保留。|Recording copy verification failed. The original was retained.|録音コピーの検証に失敗しました。元の録音は保持されています。
    录音复制校验失败，原录音保留。|錄音複製校驗失敗，原錄音保留。|Recording copy verification failed. The original recording was retained.|録音のコピー検証に失敗しました。元の録音は保持されています。
    录音引用或时间映射不完整。|錄音引用或時間映射不完整。|A recording reference or timeline mapping is incomplete.|録音への参照または時間の対応付けが不完全です。
    录音所在的转写保存位置尚未连接。|錄音所在的轉寫保存位置尚未連接。|The transcript storage containing this recording is not connected.|この録音を含む文字起こしの保存先に接続していません。
    录音目标已有不同内容，未覆盖。|錄音目標已有不同內容，未覆蓋。|The recording destination contains different content. It was not overwritten.|録音先に異なる内容があります。上書きしていません。
    快照期间资料发生变化，旧资料未改写；请重新预检。|快照期間資料發生變化，舊資料未改寫；請重新預檢。|Materials changed during the snapshot. Original data was not rewritten. Run preflight again.|スナップショット作成中に資料が変更されました。元の資料は書き換えていません。事前確認をやり直してください。
    快照目标已存在，未覆盖。|快照目標已存在，未覆蓋。|The snapshot destination already exists. It was not overwritten.|スナップショットの保存先が既にあります。上書きしていません。
    恢复位置不能与已有课程或转写目录嵌套。|恢復位置不能與已有課程或轉寫目錄嵌套。|The restore destination must not be nested with existing course or transcript folders.|復元先と既存のコース・文字起こしフォルダを親子関係にはできません。
    恢复位置必须独立于备份和应用资料目录。|恢復位置必須獨立於備份和應用資料目錄。|Choose a restore destination separate from the backup and app data folders.|バックアップとアプリデータのフォルダとは別の復元先を選択してください。
    恢复层级循环。|恢復層級循環。|The restore hierarchy contains a cycle.|復元する階層が循環しています。
    恢复暂存资源校验失败。|恢復暫存資源校驗失敗。|Staged restore resources failed verification.|復元用の一時リソースの検証に失敗しました。
    恢复目录已有内容，原件保留在原位置。|恢復目錄已有內容，原件保留在原位置。|The recovery folder already contains data. The original remains in its original location.|復旧フォルダに既存の内容があります。元のファイルは元の場所に保持されています。
    恢复附件标识与现有附件冲突，未覆盖。|恢復附件標識與現有附件衝突，未覆蓋。|The restored attachment identity conflicts with an existing attachment. Nothing was overwritten.|復元する添付ファイルの識別子が既存の添付ファイルと競合しています。上書きしていません。
    所选位置与课程资料不一致，尚未重新定位。|所選位置與課程資料不一致，尚未重新定位。|The selected location does not match the course materials. The location has not been updated.|選択した場所がコース資料と一致しません。保存場所は未変更です。
    批注与版本复制校验失败。原件与暂存副本已保留。|批注與版本複製校驗失敗。原件與暫存副本已保留。|Annotation and version copy verification failed. Originals and staged copies were retained.|注釈とバージョンのコピー検証に失敗しました。元データと一時コピーを保持しています。
    找不到父文件夹。|找不到父文件夾。|The parent folder could not be found.|親フォルダが見つかりません。
    支持 PDF、ULecture 笔记、Markdown、TXT、PPT 和 PPTX。此文件未导入。|支持 PDF、ULecture 筆記、Markdown、TXT、PPT 和 PPTX。此文件未導入。|Supported formats are PDF, ULecture notes, Markdown, TXT, PPT, and PPTX. This file was not imported.|PDF、ULecture ノート、Markdown、TXT、PPT、PPTX に対応しています。このファイルは読み込んでいません。
    文件不在指定课程目录内。|文件不在指定課程目錄內。|The file is outside the specified course folder.|ファイルが指定コースのフォルダ内にありません。
    文件夹不可写，内容尚未保存。|文件夾不可寫，內容尚未保存。|The folder is not writable. Content has not been saved.|フォルダに書き込めません。内容は未保存です。
    文件尚未迁移到课程工作文件夹。|文件尚未遷移到課程工作文件夾。|The file has not been migrated to the course working folder.|ファイルはまだコースの作業フォルダに移行されていません。
    文件已创建，但目录索引尚未保存；请刷新。|文件已創建，但目錄索引尚未保存；請刷新。|The file was created, but the folder index is not saved. Refresh to retry.|ファイルは作成されましたが、フォルダ索引は未保存です。更新して再試行してください。
    文件已在外部移动或删除，请刷新或重新定位。|文件已在外部移動或刪除，請刷新或重新定位。|The file was moved or deleted outside the app. Refresh or locate it again.|ファイルがアプリ外で移動または削除されました。更新するか、場所を指定し直してください。
    文件已复制，索引未完成；请刷新。|文件已複製，索引未完成；請刷新。|The file was copied, but indexing is incomplete. Refresh to retry.|ファイルはコピーされましたが、索引作成は未完了です。更新して再試行してください。
    文件操作恢复记录无效，原件保持不变。|文件操作恢復記錄無效，原件保持不變。|The file-operation recovery record is invalid. Originals are unchanged.|ファイル操作の復旧記録が無効です。元のファイルは変更していません。
    文档元数据缺少身份。|文檔元數據缺少身份。|Document metadata is missing its identity.|文書のメタデータに識別子がありません。
    无法创建数据库快照。|無法創建數據庫快照。|Could not create the database snapshot.|データベースのスナップショットを作成できません。
    无法封存数据库快照。|無法封存數據庫快照。|Could not finalize the database snapshot.|データベースのスナップショットを確定できません。
    无法开始数据库一致性快照。|無法開始數據庫一致性快照。|Could not start a consistent database snapshot.|整合性のあるデータベーススナップショットを開始できません。
    无法读取文件身份。|無法讀取文件身份。|Could not read the file identity.|ファイルの識別情報を読み取れません。
    无法读取资料目录。|無法讀取資料目錄。|Could not read the materials folder.|資料フォルダを読み取れません。
    旧库在快照后已有修改。原快照与新修改均保留；请重新预检，不能继续旧任务。|舊庫在快照後已有修改。原快照與新修改均保留；請重新預檢，不能繼續舊任務。|The old library changed after the snapshot. Both were retained. Run preflight again; this task cannot continue.|スナップショット作成後に旧ライブラリが変更されました。両方を保持しています。事前確認をやり直してください。旧処理は続行できません。
    旧录音校验失败，原件保留且尚未迁移。|舊錄音校驗失敗，原件保留且尚未遷移。|Legacy recording verification failed. The original was retained and has not been migrated.|旧録音の検証に失敗しました。元の録音を保持し、移行していません。
    旧资料层级包含缺失引用。|舊資料層級包含缺失引用。|The legacy material hierarchy has missing references.|旧資料の階層に欠落した参照があります。
    旧资料库仍在使用，请关闭旧版本再迁移。|舊資料庫仍在使用，請關閉舊版本再遷移。|The legacy library is still in use. Close the old app before migrating.|旧ライブラリが使用中です。旧アプリを終了してから移行してください。
    旧资料库缺少写入锁，不能确认一致性。|舊資料庫缺少寫入鎖，不能確認一致性。|The legacy library has no write lock. Consistency cannot be confirmed.|旧ライブラリの書き込みロックがありません。整合性を確認できません。
    旧附件校验失败，迁移未提交。|舊附件校驗失敗，遷移未提交。|Legacy attachment verification failed. Migration was not committed.|旧添付ファイルの検証に失敗しました。移行は未確定です。
    未完成迁移副本需要检查，已保留。|未完成遷移副本需要檢查，已保留。|The unfinished migration copy needs inspection and was retained.|未完了の移行コピーは確認が必要なため保持されています。
    未知转写数据库，未改写。|未知轉寫數據庫，未改寫。|The transcript database format is unknown. It was not rewritten.|不明な文字起こしデータベースです。書き換えていません。
    此会话尚无转写数据。|此會話尚無轉寫數據。|This session has no transcript data yet.|このセッションにはまだ文字起こしデータがありません。
    此会话属于另一资料库，未自动导入。|此會話屬於另一資料庫，未自動導入。|This session belongs to another library and was not imported automatically.|このセッションは別のライブラリに属するため、自動で読み込んでいません。
    此位置属于转写存储或应用资料；请选择其他课程文件夹。|此位置屬於轉寫儲存或應用程式資料；請選擇其他課程資料夾。|This location is inside transcript storage or application data. Choose another course folder.|この場所は文字起こしまたはアプリデータの保存領域内です。別のコースフォルダを選んでください。
    此文件夹包含或属于转写存储或应用资料，不能移动、重命名或删除。请先在设置中更改相应保存位置。|此資料夾包含或屬於轉寫儲存或應用程式資料，不能移動、重新命名或刪除。請先在設定中更改相應儲存位置。|This folder contains or belongs to transcript storage or application data. It cannot be moved, renamed or deleted. Change that storage location in Settings first.|このフォルダは文字起こしやアプリデータの保存領域を含むか、その領域内にあります。移動・名前の変更・削除はできません。先に設定で保存先を変更してください。
    此旧资料需先迁移到课程工作文件夹。|此舊資料需先遷移到課程工作文件夾。|Migrate this legacy material to a course working folder first.|この旧資料を先にコースの作業フォルダへ移行してください。
    此转写属于另一资料库，未改写。|此轉寫屬於另一資料庫，未改寫。|This transcript belongs to another library. It was not rewritten.|この文字起こしは別のライブラリに属します。書き換えていません。
    没有已保存的关联转写，未生成空导出。|沒有已保存的關聯轉寫，未生成空導出。|No saved linked transcript is available. No empty export was created.|関連する保存済み文字起こしがないため、空のファイルは書き出していません。
    目标包含其他转写迁移任务，未覆盖：|目標包含其他轉寫遷移任務，未覆蓋：|The destination contains another transcript migration task. Nothing was overwritten:|移行先に別の文字起こし移行処理があります。上書きしていません：
    目标同名文件占用了文件夹位置，原件未覆盖。|目標同名文件佔用了文件夾位置，原件未覆蓋。|A file with the same name occupies the destination folder path. The original was not overwritten.|移行先のフォルダ名と同名のファイルがあります。元のファイルは上書きしていません。
    目标已删除。|目標已刪除。|The destination was deleted.|移動先は削除されています。
    目标已存在，请使用新的备份名称。|目標已存在，請使用新的備份名稱。|The destination already exists. Use a new backup name.|保存先が既にあります。新しいバックアップ名を指定してください。
    目标已有同名文件，请先重命名或选择其他文件夹。|目標已有同名文件，請先重命名或選擇其他文件夾。|A file with this name already exists. Rename it or choose another folder.|同名のファイルが既にあります。名前を変更するか、別のフォルダを選択してください。
    目标已有同名文件；没有覆盖或移动。|目標已有同名文件；沒有覆蓋或移動。|A file with this name already exists at the destination. Nothing was overwritten or moved.|移動先に同名のファイルがあります。上書き・移動はしていません。
    目标已有同名项目，请使用其他名称。|目標已有同名項目，請使用其他名稱。|An item with this name already exists. Use another name.|同名の項目が既にあります。別の名前を指定してください。
    目标批注/版本资源冲突，文件操作等待恢复。|目標批注/版本資源衝突，文件操作等待恢復。|Destination annotations or version resources conflict. The file operation is awaiting recovery.|移動先の注釈またはバージョンリソースが競合しています。ファイル操作は復旧待ちです。
    目标有同名内容，未覆盖；请处理冲突后继续迁移。|目標有同名內容，未覆蓋；請處理衝突後繼續遷移。|The destination contains an item with this name. Nothing was overwritten. Resolve the conflict before continuing migration.|移行先に同名の内容があります。上書きしていません。競合を解消してから移行を続けてください。
    目标附件冲突，现有内容未覆盖。|目標附件衝突，現有內容未覆蓋。|Destination attachments conflict. Existing content was not overwritten.|移行先の添付ファイルが競合しています。既存の内容は上書きしていません。
    移动已提交，但原位置随后有新修改；两份内容都已保留，需要手动处理。|移動已提交，但原位置隨後有新修改；兩份內容都已保留，需要手動處理。|The move was committed, but the original location changed afterward. Both copies were retained and need manual review.|移動は確定しましたが、その後に元の場所が変更されました。両方を保持しています。手動で確認してください。
    移动期间会话有新保存，请重试；原位置保持有效。|移動期間會話有新保存，請重試；原位置保持有效。|The session was saved during the move. Retry; the original location remains active.|移動中にセッションが保存されました。再試行してください。元の保存先は有効なままです。
    移动期间文件已改变；保留原件与恢复副本，尚未提交。|移動期間文件已改變；保留原件與恢復副本，尚未提交。|The file changed during the move. The original and recovery copy were retained; the move is not committed.|移動中にファイルが変更されました。元データと復旧用コピーを保持し、移動は確定していません。
    移动转写时录音有变化，原位置仍有效。|移動轉寫時錄音有變化，原位置仍有效。|Recordings changed while moving transcripts. The original location remains active.|文字起こしの移動中に録音が変更されました。元の保存先は有効です。
    稳定标识与现有资料冲突，未覆盖。|穩定標識與現有資料衝突，未覆蓋。|The stable identity conflicts with existing materials. Nothing was overwritten.|固定識別子が既存の資料と競合しています。上書きしていません。
    笔记/批注版本冲突，两份资料均保留。|筆記/批注版本衝突，兩份資料均保留。|Note or annotation versions conflict. Both copies were retained.|ノートまたは注釈のバージョンが競合しています。両方の資料を保持しています。
    笔记或批注引用了备份范围外资料。|筆記或批注引用了備份範圍外資料。|A note or annotation references materials outside the backup scope.|ノートまたは注釈がバックアップ範囲外の資料を参照しています。
    请先移动到相同文件夹，再调整顺序。|請先移動到相同文件夾，再調整順序。|Move the items into the same folder before reordering.|同じフォルダに移動してから順序を変更してください。
    请选择文件夹或笔记。|請選擇文件夾或筆記。|Select a folder or note.|フォルダまたはノートを選択してください。
    请选择未关联的独立会话和有效课程。|請選擇未關聯的獨立會話和有效課程。|Select an unassociated standalone session and a valid course.|未関連付けの独立セッションと有効なコースを選択してください。
    请选择空文件夹；未覆盖已有内容。|請選擇空文件夾；未覆蓋已有內容。|Choose an empty folder. Existing content was not overwritten.|空のフォルダを選択してください。既存の内容は上書きしていません。
    不支持导入整个文件夹，请选择具体资料文件。|不支援匯入整個資料夾，請選擇具體資料檔案。|Import individual documents instead of an entire folder.|フォルダ全体ではなく、個別の資料ファイルを選択してください。
    请选择课程或文件夹。|請選擇課程或文件夾。|Select a course or folder.|コースまたはフォルダを選択してください。
    请选择课程文件夹。|請選擇課程文件夾。|Select a course folder.|コースのフォルダを選択してください。
    课程不存在。|課程不存在。|The course does not exist.|コースが存在しません。
    课程包含无法定位的父级。|課程包含無法定位的父級。|The course contains a parent item that cannot be located.|コース内に場所を特定できない親項目があります。
    课程尚未选择工作文件夹。|課程尚未選擇工作文件夾。|A working folder has not been selected for this course.|このコースの作業フォルダは未選択です。
    课程已经迁移；请使用重新定位或移动功能。|課程已經遷移；請使用重新定位或移動功能。|The course was already migrated. Use Locate or Move.|コースは移行済みです。場所の再指定または移動機能を使ってください。
    课程文件夹不能互相嵌套；请选择独立文件夹。|課程文件夾不能互相嵌套；請選擇獨立文件夾。|Course folders must not be nested. Choose separate folders.|コースのフォルダは親子関係にできません。独立したフォルダを選択してください。
    课程文件夹未连接，请重新连接磁盘或定位文件夹。|課程文件夾未連接，請重新連接磁盤或定位文件夾。|The course folder is disconnected. Reconnect the disk or locate the folder.|コースフォルダに接続していません。ディスクを再接続するか、フォルダを指定してください。
    课程通过拖放排序；课堂关联保持原课程。|課程通過拖放排序；課堂關聯保持原課程。|Drag courses to reorder them. Classrooms retain their original course association.|コースはドラッグで並べ替えられます。授業は元のコースとの関連付けを維持します。
    资料关联有缺失，备份未完成。|資料關聯有缺失，備份未完成。|Material links are missing. The backup is incomplete.|資料の関連付けが欠落しています。バックアップは未完了です。
    资料包含符号链接，不能安全复制。|資料包含符號鏈接，不能安全複製。|The materials contain symbolic links and cannot be copied safely.|資料にシンボリックリンクが含まれるため、安全にコピーできません。
    资料库标识无效。|資料庫標識無效。|The library identity is invalid.|ライブラリの識別子が無効です。
    资料条目不存在。|資料條目不存在。|The material item does not exist.|資料の項目が存在しません。
    转写会话标识无效。|轉寫會話標識無效。|The transcript session identity is invalid.|文字起こしセッションの識別子が無効です。
    转写位置不能与原位置或应用资料目录嵌套。|轉寫位置不能與原位置或應用資料目錄嵌套。|Transcript storage must not be nested with the original location or app data folder.|文字起こしの保存先は、元の保存先やアプリデータのフォルダと親子関係にはできません。
    转写位置已被其他操作更改。|轉寫位置已被其他操作更改。|Another operation changed the transcript location.|別の操作によって文字起こしの保存先が変更されました。
    转写位置必须独立于课程资料文件夹。|轉寫位置必須獨立於課程資料文件夾。|Transcript storage must be separate from course material folders.|文字起こしの保存先はコース資料のフォルダとは別にしてください。
    转写保存位置无法打开。|轉寫保存位置無法打開。|The transcript storage location could not be opened.|文字起こしの保存先を開けません。
    转写保存位置未连接。|轉寫保存位置未連接。|The transcript storage location is disconnected.|文字起こしの保存先に接続していません。
    转写快照含其他会话记录。|轉寫快照含其他會話記錄。|The transcript snapshot contains records from another session.|文字起こしスナップショットに別セッションの記録が含まれています。
    转写数据库完整性检查失败。|轉寫數據庫完整性檢查失敗。|The transcript database failed its integrity check.|文字起こしデータベースの整合性検査に失敗しました。
    转写时间或归属无效。|轉寫時間或歸屬無效。|The transcript timing or ownership is invalid.|文字起こしの時間または所属が無効です。
    转写格式较新，未改写。|轉寫格式較新，未改寫。|The transcript uses a newer format. It was not rewritten.|文字起こしは新しい形式です。書き換えていません。
    转写课程目录不是普通目录。|轉寫課程目錄不是普通目錄。|The transcript course folder is not a regular directory.|文字起こしのコース保存先が通常のフォルダではありません。
    转写迁移任务标识无效。|轉寫遷移任務標識無效。|The transcript migration task identity is invalid.|文字起こし移行処理の識別子が無効です。
    迁移任务与已保存身份不一致。|遷移任務與已保存身份不一致。|The migration task does not match the saved identity.|移行処理が保存済みの識別子と一致しません。
    迁移任务版本不匹配，已有快照保留。|遷移任務版本不匹配，已有快照保留。|The migration task version does not match. Existing snapshots were retained.|移行処理のバージョンが一致しません。既存のスナップショットは保持されています。
    迁移复制校验失败。|遷移複製校驗失敗。|Migration copy verification failed.|移行コピーの検証に失敗しました。
    迁移快照实体数量不一致。|遷移快照實體數量不一致。|The migration snapshot item count does not match.|移行スナップショットの項目数が一致しません。
    迁移快照已改变，未继续。|遷移快照已改變，未繼續。|The migration snapshot has changed. Migration did not continue.|移行スナップショットが変更されています。移行は続行していません。
    迁移快照附件校验失败。|遷移快照附件校驗失敗。|Migration snapshot attachment verification failed.|移行スナップショットの添付ファイル検証に失敗しました。
    迁移批注版本冲突，未覆盖。|遷移批注版本衝突，未覆蓋。|Migration annotation versions conflict. Nothing was overwritten.|移行する注釈のバージョンが競合しています。上書きしていません。
    迁移暂存副本有变化，尚未提交。|遷移暫存副本有變化，尚未提交。|The staged migration copy has changed. Migration is not committed.|移行用の一時コピーが変更されています。移行は未確定です。
    迁移暂存校验失败，原位置保持有效。|遷移暫存校驗失敗，原位置保持有效。|Migration staging verification failed. The original location remains active.|移行用一時データの検証に失敗しました。元の保存先は有効です。
    迁移条目缺失。|遷移條目缺失。|A migration item is missing.|移行対象の項目がありません。
    迁移源快照已变化，未覆盖既有修改。|遷移源快照已變化，未覆蓋既有修改。|The migration source snapshot has changed. Existing edits were not overwritten.|移行元のスナップショットが変更されています。既存の編集は上書きしていません。
    迁移目标已有后续编辑，未覆盖；请选择新的转写位置。|遷移目標已有後續編輯，未覆蓋；請選擇新的轉寫位置。|The migration destination has subsequent edits. Nothing was overwritten. Select a new transcript location.|移行先に後から行われた編集があります。上書きしていません。新しい文字起こし保存先を選択してください。
    迁移目标已经变化，未覆盖。|遷移目標已經變化，未覆蓋。|The migration destination has changed. It was not overwritten.|移行先が変更されています。上書きしていません。
    迁移附件副本校验失败。|遷移附件副本校驗失敗。|Migrated attachment copy verification failed.|移行した添付ファイルのコピー検証に失敗しました。
    采集硬件仍在使用或停止中。|採集硬件仍在使用或停止中。|Capture hardware is still in use or stopping.|収録用のハードウェアが使用中、または停止処理中です。
    附件校验失败，备份未完成。|附件校驗失敗，備份未完成。|Attachment verification failed. The backup is incomplete.|添付ファイルの検証に失敗しました。バックアップは未完了です。
    离线模型已损坏；请重新下载离线模型。原文件已保留。|離線模型已損壞；請重新下載離線模型。原文件已保留。|The offline model is damaged. Download it again. The original file was retained.|オフラインモデルが破損しています。再ダウンロードしてください。元のファイルは保持されています。
    尚未下载离线模型；下载后即可离线转写。|尚未下載離線模型；下載後即可離線轉寫。|The offline model has not been downloaded. Download it to enable offline transcription.|オフラインモデルは未ダウンロードです。ダウンロードするとオフライン文字起こしを使用できます。
    已准备完成，可启用离线转写|已準備完成，可啟用離線轉寫|Ready to enable offline transcription|準備が完了しました。オフライン文字起こしを有効にできます
    启动已取消；请手动继续|啟動已取消；請手動繼續|Start cancelled; resume manually|開始をキャンセルしました。手動で再開してください
    尚未保存当前服务的 API Key|尚未儲存目前服務的 API Key|No API key is saved for the current service|現在のサービスの API キーは未保存です
    模型已停用，请更新应用预设后重试|模型已停用，請更新應用程式預設後重試|The model is retired. Update the app preset before retrying|モデルは提供終了しています。アプリの設定を更新してから再試行してください
    试音时限已到；采集已停止|試音時限已到；擷取已停止|Input test time limit reached; capture stopped|入力テストの制限時間に達しました。収録を停止しました
    附件身份重复。|附件識別資訊重複。|Attachment identities are duplicated.|添付ファイルの識別子が重複しています。
    音频启动超时；正在停止，请等待后手动重试。|音訊啟動逾時；正在停止，請等待後手動重試。|Audio startup timed out. Stopping now; wait, then retry manually.|音声の開始がタイムアウトしました。停止処理が終わるまで待ち、手動で再試行してください。
    音频硬件停止失败；请退出重开，不能自动继续。|音訊硬體停止失敗；請結束並重新開啟，不能自動繼續。|Audio hardware could not stop. Quit and reopen the app; automatic resume is disabled.|音声ハードウェアを停止できません。アプリを終了して開き直してください。自動再開はしません。
    目标包含其他转写迁移任务，未覆盖：{0}|目標包含其他轉寫移轉工作，未覆寫：{0}|The destination contains another transcript migration task. Nothing was overwritten: {0}|移行先に別の文字起こし移行処理があります。上書きしていません：{0}
    已恢复文件操作：{0}|已復原檔案操作：{0}|File operation recovered: {0}|ファイル操作を復旧しました：{0}
    保留未完成操作的原件：{0}|保留未完成操作的原檔：{0}|Original retained for the unfinished operation: {0}|未完了操作の元ファイルを保持しています：{0}
    操作两端均未连接，需要重新定位：{0}|操作兩端均未連線，需要重新定位：{0}|Both operation locations are disconnected. Locate them again: {0}|操作元と操作先が切断されています。場所を指定し直してください：{0}
    恢复目标已被修改，保留两端等待处理：{0}|復原目標已被修改，保留兩端等待處理：{0}|Recovery destination changed; both copies are retained for review: {0}|復旧先が変更されています。確認用に両方を保持しています：{0}
    文件操作仍待恢复：{0}|檔案操作仍待復原：{0}|File operation still needs recovery: {0}|ファイル操作は引き続き復旧が必要です：{0}
    同一会话标识存在多个数据库；保留全部原件，等待选择恢复来源。|同一會話識別資訊存在多個資料庫；保留全部原檔，等待選擇復原來源。|Multiple databases share this session identity. All originals are retained; select a recovery source.|同じセッション識別子のデータベースが複数あります。すべての元データを保持しています。復元元を選択してください。
    不支持此旧备份格式或规模。|不支援此舊備份格式或規模。|This legacy backup format or size is not supported.|この旧バックアップの形式または規模には対応していません。
    已准备的旧备份转换校验失败，未写入现有资料。|已準備的舊備份轉換驗證失敗，未寫入現有資料。|The prepared legacy backup conversion failed verification. Existing data was not changed.|準備済みの旧バックアップ変換の検証に失敗しました。既存データは変更していません。
    已恢复对象后来被移除，未重复恢复或覆盖现有资料。|已復原物件後來被移除，未重複復原或覆寫現有資料。|A previously restored item was later removed. It was not restored again, and existing data was not overwritten.|以前復元した項目が後から削除されています。再復元や既存データの上書きは行っていません。
    旧备份含符号链接或可执行内容，已拒绝。|舊備份含符號連結或可執行內容，已拒絕。|The legacy backup contains symbolic links or executable content and was rejected.|旧バックアップにシンボリックリンクまたは実行可能な内容が含まれるため、受け付けませんでした。
    旧备份在转换期间发生变化，请重新选择。|舊備份在轉換期間發生變化，請重新選擇。|The legacy backup changed during conversion. Select it again.|変換中に旧バックアップが変更されました。選択し直してください。
    旧备份复制期间附件改变，转换未提交。|舊備份複製期間附件改變，轉換未提交。|An attachment changed while copying the legacy backup. The conversion was not committed.|旧バックアップのコピー中に添付ファイルが変更されました。変換結果は確定していません。
    旧备份根对象缺失。|舊備份根物件缺失。|The root item of the legacy backup is missing.|旧バックアップのルート項目がありません。
    旧备份清单无效或过大。|舊備份清單無效或過大。|The legacy backup manifest is invalid or too large.|旧バックアップの一覧が無効か、大きすぎます。
    旧备份转换锁无法打开。|舊備份轉換鎖無法開啟。|The legacy backup conversion lock could not be opened.|旧バックアップ変換用のロックを開けません。
    旧备份附件清单无效或重复。|舊備份附件清單無效或重複。|The legacy backup attachment list is invalid or contains duplicates.|旧バックアップの添付ファイル一覧が無効か、重複しています。
    旧备份附件缺失或校验失败。|舊備份附件缺失或驗證失敗。|A legacy backup attachment is missing or failed verification.|旧バックアップの添付ファイルがないか、検証に失敗しました。
    此旧备份正在恢复，请等待当前操作结束。|此舊備份正在復原，請等待目前操作結束。|This legacy backup is being restored. Wait for the current operation to finish.|この旧バックアップは復元中です。現在の処理が終わるまでお待ちください。
    """

    struct Template {
        let source: String
        let translations: [String]
        let expression: NSRegularExpression?
        init(_ fields: [String]) {
            source = fields[0]; translations = fields
            if source.contains("{0}") {
                let parts = source.components(separatedBy: "{0}")
                let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
                expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            } else { expression = nil }
        }
    }
    static let templates: [Template] = rows.split(separator: "\n").map {
        Template($0.split(separator: "|", omittingEmptySubsequences: false).map(String.init))
    }
    static let exact = Dictionary(uniqueKeysWithValues: templates.filter { $0.expression == nil }.map { ($0.source, $0.translations) })
    static let codeKeys: [String:String] = [
        "interpretation.serviceBusy":"interpretation.serviceBusy",
        "interpretation.invalidConfiguration":"interpretation.invalidConfiguration",
        "interpretation.incompatibleModel":"interpretation.incompatibleModel",
        "interpretation.unsupportedLanguage":"interpretation.unsupportedLanguage",
        "interpretation.missingCredential":"interpretation.missingCredential",
        "interpretation.authentication":"interpretation.authentication",
        "interpretation.modelUnavailable":"interpretation.modelUnavailable",
        "interpretation.rateLimited":"interpretation.rateLimited",
        "interpretation.handshakeTimeout":"interpretation.handshakeTimeout",
        "interpretation.finishTimeout":"interpretation.finishTimeout",
        "interpretation.connectionLost":"interpretation.connectionLost",
        "interpretation.protocolViolation":"interpretation.protocolViolation",
        "interpretation.audioFormat":"interpretation.audioFormat",
        "interpretation.invalidAudio":"interpretation.invalidAudio",
        "interpretation.bufferOverflow":"interpretation.bufferOverflow",
        "interpretation.cancelled":"interpretation.cancelled",
        "interpretation.sessionExpired":"interpretation.sessionExpired",
        "interpretation.serviceUnavailable":"interpretation.serviceUnavailable",
        "interpretation.invalidRecord":"interpretation.invalidRecord",
        "interpretation.conflictingCaption":"interpretation.conflictingCaption",
        "interpretation.sessionEnded":"interpretation.sessionEnded",
        "interpretation.noSourceCaptions":"interpretation.noSourceCaptions",
        "interpretation.untimedSubtitleExport":"interpretation.untimedSubtitleExport",
        "mainAIUnsupportedProvider":"mainAIUnsupportedProvider",
        "mainAIProviderMismatch":"mainAIProviderMismatch",
        "onlineHandshakePassed":"onlineHandshakePassed",
        "online.captureFailed":"online.captureFailed",
        "online.captureInterrupted":"online.captureInterrupted",
        "online-connection-gap":"online-connection-gap",
        "online-reconnect-failed":"online-reconnect-failed",
        "online-session-rotation":"online-session-rotation",
        "online-start-failed":"online-start-failed",
        "online-unsent-audio-discarded":"online-unsent-audio-discarded",
        "Library closed":"libraryClosed", "Library unavailable":"libraryUnavailable", "Recording staging link rejected":"recordingLinkRejected", "configuration-change":"configurationChanged",
        "waitingConfiguration":"waitingConfiguration", "waitingNetwork":"waitingNetwork", "queued":"queued", "running":"running", "saving":"saving", "retryWaiting":"retryWaiting", "completed":"completed", "needsAttention":"needsAttention", "obsolete":"obsolete", "partial":"partial", "pending":"queued", "cancelled":"cancelled", "interrupted":"interrupted", "failed":"failed", "idle":"idle", "userPaused":"userPaused", "unverified":"unverified", "testing":"testing", "requestSucceededAccountUnverified":"requestSucceededAccountUnverified",
        "missingCredential":"missingCredential", "invalidConfiguration":"invalidConfiguration", "expiredPreset":"expiredPreset", "network":"cloudNetwork", "authentication":"authentication", "permission":"cloudPermission", "quota":"quota", "rateLimited":"rateLimited", "unavailable":"unavailable", "malformedResponse":"malformedResponse", "persistence":"persistence", "queueFull":"queueFull", "noMaterials":"noMaterials", "responseTooLarge":"responseTooLarge",
        "interruptedUsageUnknown":"interruptedUsageUnknown", "restoredRequestOutcomeUnknown":"interruptedUsageUnknown",
        "user-paused":"userPaused", "paused-no-audio":"pausedNoAudio", "storage-failure":"storageFailure", "storage-backpressure":"storageBackpressure", "window-closed":"windowClosed", "application-closed":"applicationClosed", "asr-overload-audio-not-transcribed":"asrOverload", "asr-failed-unconfirmed-tail":"asrUnconfirmedTail", "recovered-interruption-wall-clock-estimate":"estimatedGap"
    ]
    static func detail(_ raw: String, language: String) -> String {
        if let key = codeKeys[raw] { return Localizer.string(key, language: language) }
        let index = ["zh-Hans":0,"zh-Hant":1,"en":2,"ja":3][language] ?? 2
        if let values = exact[raw] { return values[index] }
        for template in templates {
            guard let expression = template.expression,
                  let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: raw) else { continue }
            let dynamic = String(raw[range])
            // Recursive translation is only for a nested known diagnostic; arbitrary filenames remain unchanged.
            let translated = exact[dynamic] != nil || codeKeys[dynamic] != nil ? detail(dynamic, language: language) : dynamic
            return template.translations[index].replacingOccurrences(of: "{0}", with: translated)
        }
        if raw.contains("\n") { return raw.components(separatedBy: "\n").map { detail($0, language: language) }.joined(separator: "\n") }
        return raw // OS-generated errors and user-owned filenames remain the original diagnostic.
    }
    static func cloudStatus(_ status: String, language: String) -> String { detail(status, language: language) }
}

#if !LOCALIZATION_TESTING
@MainActor extension AppModel {
    func detail(_ raw: String) -> String { StatusLocalizer.detail(raw, language: preferences.resolvedLanguage) }
    func cloudStatus(_ status: String) -> String { StatusLocalizer.cloudStatus(status, language: preferences.resolvedLanguage) }
}
#endif
