# 第三方组件、模型与素材

ULecture 自有源码采用 AGPL-3.0-only。以下组件独立保留其许可证；根目录许可证不重新许可第三方代码、模型权重或字体。完整通知随应用保留在 `Contents/Resources/Licenses`、`Conversion`、`BabelDOC/runtime` 和 LibreOffice 应用资源内。

## 应用中的主要组件

| 组件 | 固定版本／来源 | 分发许可与处理 |
| --- | --- | --- |
| whisper.cpp / ggml | `927cfce34f31707e17f2bff35c349632fb9e2c3a` | MIT；静态链接，源码未修改，构建选项见 build-engine.sh |
| Whisper 多语 base 权重 | ggerganov/whisper.cpp revision `5359861c739e955e79d9a303bcbc70fb988958b1` | OpenAI Whisper MIT，权重大小及 SHA-256 独立锁定 |
| Silero VAD 6.2.0 权重 | ggml-org/whisper-vad revision `9ffd54a1e1ee413ddf265af9913beaf518d1639b` | MIT；GGML 转换资源和引擎许可分别保留 |
| PDFium | Chromium 7999 / `e9fc01804a0c5224ea780ad782abb8cfede628ef` | BSD 类许可及所含第三方通知；仅调整加载路径和本地签名 |
| LibreOffice | 官方 26.8.0.3 Apple Silicon | MPL-2.0 及官方 LICENSE/NOTICE 中各组件许可；独立进程，官方应用未修改 |
| CPython | 3.12.12，python-build-standalone 20260211 | Python-2.0 及其捆绑依赖通知 |
| BabelDOC | 0.6.4 | AGPL-3.0-or-later，本分发采用第 3 版；独立进程，保留对应源码和通知 |
| PyMuPDF / MuPDF | 1.28.2 / 1.28.2 | AGPL-3.0，使用开源许可；不是商业许可版本 |
| Levenshtein | 0.27.5 | GPL-2.0-or-later，本分发采用第 3 版兼容路径 |
| SciPy 内的 GCC 运行库 | GCC 13.4.0 | libgfortran/libgcc：GPL-3.0-or-later WITH GCC-exception-3.1；libquadmath：LGPL-2.1-or-later。完整条款保留在 SciPy 通知中，并提供 GNU 源码及 Darwin 构建补丁 |
| 其他 Python 包 | 85 个固定发行版本 | 完整版本、来源、哈希和许可证文本见下述清单，不仅依赖顶层包许可 |

精确二进制来源与 SHA-256：[native.lock.json](app/DependencyLocks/native.lock.json)、[models.lock.json](app/DependencyLocks/models.lock.json)。Python 发行文件：[python.lock.json](app/DependencyLocks/python.lock.json)；逐包完整通知：[python-notices.json](app/DependencyLocks/python-notices.json) 和 [许可目录](app/Resources/Licenses/Python)。

## BabelDOC 离线资源

182 个资源（字符映射、字体、布局模型和分词数据）的路径、固定 revision 和 SHA3-256 位于 [assets.lock.json](app/Resources/BabelDOC/assets.lock.json)。资源不会因为 BabelDOC 使用 AGPL 就自动获得同一许可。

- **Go Noto Universal 字体：OFL-1.1。** 其生成脚本采用 Unlicense，生成字体仍受上游 Noto 的 OFL 约束；两份说明同时保留。
- Source Han TrueType、LXGW WenKai GB/TC、Klee、Noto Sans/Serif：OFL-1.1，保留原版权、保留字体名及完整条款。
- MaruBuri：NAVER 与 NAVER Cultural Foundation 版权，官方 OFL-1.1，附官方完整声明。字体本身不单独销售，不改名宣称自有字体。
- Adobe CMap 字符映射：保留 Adobe 的 BSD 类版权许可。
- DocLayout-YOLO-DocStructBench ONNX 权重：固定模型卡声明 Apache-2.0；其代码仓库许可不能替代权重许可。保留模型卡和 Apache 条款。
- tiktoken 的 o200k_base 分词数据：配合 MIT 许可的 tiktoken 使用，固定内容哈希。

[字体和模型许可文本](app/Resources/Licenses/Assets) · [来源与通知哈希](app/DependencyLocks/asset-licenses.lock.json)

## 对应源码和重建

同版本 Release 提供 ULecture 源码及构建脚本，并提供锁定的第三方对应源码归档。也可以运行：

```sh
python3 app/scripts/collect-corresponding-source.py dist/corresponding-source
```

该脚本根据已提交锁下载并校验 Python 源码发行包、补充 native 源码和 LibreOffice 官方源代码。LibreOffice 的官方源代码入口为 [26.8.0 源码目录](https://download.documentfoundation.org/libreoffice/src/26.8.0/)；另提供其 `download.lst` 锁定的 149 份外部源码归档，覆盖 GPGME、libassuan、libgpg-error 等随包组件及其他平台的保守超集。文件名、上游来源及 SHA-256 见 [LibreOffice 外部源码锁](app/DependencyLocks/libreoffice-external-source.lock.json)，补丁和构建配方保留在官方源码的 `external/` 中。MuPDF 1.28.2 的完整源码及其第三方源码也单独保留，不能以 PyMuPDF 的 Python 源码包替代。PDFium 的固定源码及构建说明由 native 锁中链接提供。ULecture 未修改这些第三方源码；整合、构建与打包改动全部公开。

SciPy 的 arm64 macOS wheel 使用 Accelerate 和 GCC 13.4.0 运行库；版本由随包 `scipy/__config__.py` 核对。补充源码锁还保留 GNU GCC 13.4.0、该 wheel 发布前的 Homebrew Darwin 补丁与构建配方、Homebrew 许可及 SciPy 上游 wheel 工作流。原 wheel 的完整 CI 镜像和 Homebrew bottle 修订未获独立确认，因此不宣称这些第三方二进制可逐字节重建；应用构建使用已固定 SHA-256 的原始 wheel。

## 图标和宣传媒体

新图标通过生图工具原创生成，生成记录和可编辑构图素材见 [assets/brand](assets/brand)。该文件夹的项目自有素材按 [COPYRIGHT](COPYRIGHT) 提供；不包含其他应用图标。

最终宣传片配乐《Connections》由项目原创合成，仅包含器乐与电子合成音，无演唱、哼唱、旁白或声音采样。独立音轨、音符事件与生成脚本按 [COPYRIGHT](COPYRIGHT) 中的 AGPL-3.0-only 提供；随片公开分发与同步使用需保留版权、许可及对应源码。详见 [音乐许可与来源](media/music-license.md)。

独立 ASR 测试使用 Kokoro 合成的虚构英语、日语音频。英语夹具使用 Kokoro-82M-v1.1-zh 的英语管线与 `zf_001` 预设，日语使用 Kokoro-82M 的 `jf_alpha`；各自固定来源及哈希分别见 [英语夹具锁](media/fixture-voice-en-model.lock.json)与[日语夹具锁](media/fixture-voice-model.lock.json)，模型许可为 Apache-2.0。两者均为测试夹具，不进入宣传片或媒体工程 ZIP；不使用 Apple 系统声音制作公开录音。课件、字幕和学习情境为项目制作的虚构内容，不含真实用户数据。媒体文字使用已核验的 OFL 字体；系统原生界面按真实应用显示。音色模型、FFmpeg 与媒体生成器依赖不是 ULecture 应用运行时依赖，不捆绑到应用。

详见 [媒体工程与许可](media/README.md)。所有第三方商标用于说明兼容服务或来源，不代表其背书。
