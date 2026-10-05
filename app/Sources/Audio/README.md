# 音频采集与本地识别

生产代码由 ULecture 主应用静态链接。运行时不依赖 shell、Python 或外部 whisper CLI。离线模型与 VAD 的固定来源、大小和 SHA-256 由 `ModelManager` 检查。

## 数据流与生命周期

`AudioCaptureSession` 使用共享 `CaptureSessionCoordinator` 管理硬件占用。麦克风和系统音频有独立权限与设备验证；系统音频配置排除本应用声音。输入格式变化、设备断开、休眠、停止失败和超时会暂停采集，不静默切换到其他设备。

麦克风使用独立的仅输入 AUHAL，直接绑定所选设备，并在启动前后及采集中核验设备与格式。避免 AVAudioEngine 启动时按系统默认输入重建组合设备，导致非默认麦克风选择失效；不会修改系统默认音源。输入回调复用预分配 PCM 缓冲，消费者返回前必须完成复制。

每个消费者拥有独立 `AudioPCMConverter`：本地识别与录音使用 16 kHz，在线服务使用其要求的 16/24 kHz。实时转换的尾部通过 finish 排出。转换尾帧不代表字幕与音频可精确到单个采样点。

`CaptureSink` 在有界工作队列处理帧，不能在主线程执行识别。`AudioPipeline` 分段、VAD、识别和确认分别处理。临时识别使用稳定片段身份；一个临时片段可以被多个确认片段替换。确认回调包含替换关系和修订，显示层据此原位更新，持久化层只接收确认事实。

停止、暂停和退出必须等待共享 drain 与确认回调交付。已完成的录音需要实际回读校验，覆盖区间才可供回听。积压或保存错误明确报告间断，不把缺失音频伪造成转写成功。模型释放在采集与识别 drain 之后执行。

`ModelManager.restoreAtLaunch` 只读发现资源；启动不安装、不采集、不加载识别引擎。开始本地识别或主动准备模型才加载。取消使当前准备代失效，不能与旧原生加载重叠。坏缓存保留为恢复依据，经过验证后才替换。

## 测试边界

`AUDIO_TESTING` 提供静默 PCM 注入和故障注入，仅编入测试可执行文件。`check-audio.sh` 使用 `Tests/Fixtures/Audio` 中项目生成的虚构英语、日语语音，经过真实 PCM、VAD、whisper 推理、录音与回读；不读取私人音频。

- `check-audio-capture-lifecycle.sh`、`check-audio-lifecycle.sh`：生命周期、停止、设备及迟到回调的确定性检查。
- `check-microphone-device.sh --hardware`：显式启用真实麦克风检查；要求已有权限及不同于系统默认输入的内置麦克风。核验选择、实际 PCM、三次停止重启、停止后回调静默及无效设备拒绝；不保存或上传音频，不加载模型，也不更改系统音源。不满足前提时返回 BLOCKED，不能算作通过。
- `check-online-capture.sh`：无本地模型条件下共享捕获管线的 16/24 kHz 分支和边界。
- `check-model-startup.sh`、`check-model-cancellation.sh`：资源校验、真实加载、取消、恢复与主线程响应。
- `check-performance.sh`：真实本地识别回放、记录和界面测量；模拟翻译与真实云服务严格区分。

文件回放不证明麦克风、系统音频、权限、设备切换、真实服务账户或自然课堂质量通过。测试矩阵、实际硬件和未覆盖范围统一记录于根目录 [VALIDATION.md](../../../VALIDATION.md)。
