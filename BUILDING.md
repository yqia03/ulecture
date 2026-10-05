# 从源码构建

## 环境

- Apple Silicon Mac，macOS 14 或更新版本。
- Xcode 16.4 或兼容的 Swift 5 编译模式、macOS SDK；先完成 Xcode 首次启动和 `xcode-select` 配置。
- Python 3 用于下载校验及打包脚本；`rg` 用于源码枚举。CMake、uv、运行时 Python、模型和转换器由下述脚本安装到项目内。
- 足够的磁盘空间：完整依赖、构建缓存、应用和打包会占用数 GB，建议预留 15 GB。首次准备需要联网下载已锁定输入；应用运行不需要下载这些构建工具。

```sh
git clone https://github.com/yqia03/ulecture.git
cd ulecture
python3 app/scripts/bootstrap.py
python3 app/scripts/build-icon.py
bash app/scripts/build.sh
open app/build/ULecture.app
```

`bootstrap.py` 可重入，下载前检查已有归档，下载后核对 SHA-256，再安装到忽略的 `app/Dependencies` 和 `app/Resources/Models`。不使用机器私有安装目录。BabelDOC 的 182 个资源通过固定 revision 与 SHA3-256 验证；Python 包使用完整哈希锁安装。

大型文件不进入 Git。精确版本、来源、文件哈希及许可位于 `app/DependencyLocks`；Python 完整依赖锁位于 `app/Resources/BabelDOC`。第三方代码保持原许可证，自有代码使用根目录 AGPL-3.0-only。

## 构建与签名

`build.sh` 创建隔离源码快照，编译 Swift/SwiftUI 和本地 whisper.cpp，打包 PDFium、LibreOffice、BabelDOC 及离线模型，再生成输入清单、源码哈希和本地临时签名。旧构建保留在 `app/build/ULecture.previous-*`。

发行构建去除本机源码路径，并清理转换器暂存副本的 Python 生成缓存，保留源文件；转换子进程禁止写入字节码。`verify-package.py` 会拒绝残留缓存。

源码提交、资源锁和完整构建清单用于对应制品。编译器、系统 SDK、临时签名及资源归档可能使不同机器的最终字节不完全相同，不能仅凭版本号声称二进制可逐字节复现。

当前没有可用 Developer ID，因此公开包未公证。有证书的维护者应按组件依赖顺序签名嵌套可执行文件和框架，再签主应用，启用 hardened runtime 与安全时间戳，通过 `notarytool` 公证并 staple，最后在带下载隔离属性的副本上重新安装启动。不要将临时签名改写为已公证。

## 验证入口

```sh
bash app/scripts/check-transcript-text.sh
bash app/scripts/check-transcript-recovery.sh
bash app/scripts/check-relocation.sh
bash app/scripts/check-archive.sh
bash app/scripts/check-subtitle-rolling.sh
bash app/scripts/check-cloud-durability.sh
python3 app/Tests/PythonRelocationChecks.py
python3 app/Tests/check-python-cache-hygiene.py
bash app/scripts/check-integration.sh "$(mktemp -d /tmp/ulecture-integration-XXXXXX)"
bash app/scripts/check-full-ui-render.sh "$(mktemp -d /tmp/ulecture-ui-XXXXXX)"
```

测试在独立临时目录或忽略的输出目录产生数据，不读取个人课程。动态字幕、实际本地识别回放、模拟网络和真实服务验证分别记录。性能比较需使用相同优化构建、硬件、电源和夹具，并排除同时编码或编译的测量窗口。长时间回放必须记录真实墙钟时长，不能用加速模拟代替三小时。

三小时持续回放使用全新输出目录，并要求接通电源、保持开盖；系统睡眠会使本次回放中断，睡眠时间不计作有效运行：

```sh
PERFORMANCE_SECONDS=11000 PERFORMANCE_DATASET=full \
PERFORMANCE_PRODUCTION_WORKLOAD=1 PERFORMANCE_LONG_ONLY=1 \
  bash app/scripts/check-performance.sh "$(mktemp -d /tmp/ulecture-soak-XXXXXX)"
```

此驱动包含实际本地 ASR、录音写入、模拟翻译、周期暂停恢复和可恢复服务失败。它不请求真实云服务，也不代替真实麦克风或系统音频权限检查。检查结束状态、实际音频帧、保存与重开结果，不能只根据进程存活时间判定通过。

11000 秒为周期暂停和排空预留余量，验收仍要求有效采集时长不少于 10800 秒。在驱动开始回放前，另开终端运行 `python3 app/scripts/monitor-performance.py <同一个全新输出目录>`；独立监测器记录清醒时间、系统睡眠、观察间隔和电源。睡眠、持续停滞或监测器失败会写入失效状态并请求安全停止。结束后运行 `python3 app/scripts/audit-performance-data.py <输出目录>`，逐字节对照两份 TXT 与正确修订的已保存数据。保留原始日志于本机，公开报告仅使用脱敏汇总。

已有系统权限时，可主动运行真实硬件短测；它们不会弹出权限请求、改变默认设备或上传声音：

```sh
bash app/scripts/check-microphone-device.sh --hardware "$(mktemp -d /tmp/ulecture-mic-XXXXXX)"
bash app/scripts/check-system-audio-hardware.sh --hardware "$(mktemp -d /tmp/ulecture-system-audio-XXXXXX)"
```

麦克风检查要求当前存在一个不同于系统默认输入的内置麦克风，只统计并丢弃 PCM。系统音频检查会播放 12 秒虚构英语语音，经过真实采集和本地识别；识别正文只在内存中检查，不保存。两者都不能代替持续验证或云服务验收。

完整结果和测试边界见 [VALIDATION.md](VALIDATION.md)。媒体生成步骤见 [media/README.md](media/README.md)。

## 发行材料

同版本 Release 提供应用、安装包、SHA-256、构建清单、对应源码、第三方通知和宣传媒体。`dist/` 整体不提交至 Git。发布前仅暂存审核过的文件，并检查全部将推送的历史中不存在凭据、私人资料、个人绝对路径或过大二进制。

维护者在推送前运行 `python3 app/scripts/audit-public.py <拟发布提交> --output <私有审查报告路径>`，扫描该提交的全部可达历史、文件名、大小、凭据模式和个人绝对路径。扫描工具不会暂存或推送文件；它不能代替逐项审查与媒体隐私检查。

本地验包后可用 `package-release.py --app <已验应用路径> --output <新的输出目录>` 制作 ZIP/DMG；脚本验证签名、ZIP 解包一致性和 DMG 结构，但不宣称已公证或已通过隔离下载后的系统授权。`package-corresponding-source.py <已校验源码目录> <新的输出目录>` 将第三方源码分为独立归档；每个附件须低于 [GitHub 的 2 GiB 限制](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。公开前仍须核对全部分发文件及最终 SHA-256。
