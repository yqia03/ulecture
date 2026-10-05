# 文件阅读、翻译与导出

ULecture 1.1.0 的文件工具支持 BabelDOC 与内置引擎。PDF/PPT/PPTX 默认通过随包 BabelDOC 0.6.4 翻译；PPT/PPTX 先由随包 LibreOffice 转为 PDF。Markdown/TXT/块笔记默认使用原有 PDFium、Vision OCR 和 CoreText 管线，以保留可编辑伴随输出；也可显式选择 BabelDOC 输出 PDF。不依赖系统安装的 PowerPoint、LibreOffice 或 Python。

BabelDOC 使用独立的“文档翻译服务”设置，支持 AI Studio、DeepSeek、OpenAI 兼容和 OpenAI 模型，或者显式选择跟随主 AI 服务。Google 使用官方 OpenAI 兼容 Gemini 端点。凭据仅经匿名 stdin 管道传给引擎，不写入命令参数、环境或任务文件。进度事件只包含百分比及阶段；提供商原始错误不展示、不落盘。引擎离线资源随包提供，翻译流程不自动下载资源。BabelDOC 的双语输出为原文/译文交替页；取消后需要重新运行该文件。旧内置任务保持原引擎。

以下详细格式覆盖说明主要描述内置管线；BabelDOC 输出需检查页面、公式、图表及扫描文字质量。

| 输入 | 阅读与处理 | 输出 |
| --- | --- | --- |
| PDF | 保留原件，提取文字与位置，保留图形 | 仅译文 PDF；源页/译页对应的双语 PDF |
| 扫描 PDF | 本机 OCR；高置信度且背景可可靠恢复的区域参与翻译 | 可搜索译文；复杂背景和低置信度区域保持原样并显示未覆盖 |
| `.ppt`、`.pptx` | 隔离的 LibreOffice 转为静态 PDF；保留源文件和幻灯片页映射 | 同一 PDF 翻译管线；不输出可编辑译后 PowerPoint |
| Markdown | 保留标题、段落、列表、引用、表格、代码及可读取的本地图片 | PDF 与可编辑 Markdown；另存 Markdown 时复制配套图片 |
| 纯文本 | 分段翻译，长内容可换页 | PDF 与文本副本 |
| `.ulnote` 笔记包 | 保留块结构、表格、代码和图片 | PDF 与独立 ID 的新笔记包，不覆盖原笔记 |

语言方向为英语或日语到简体或繁体中文。文件任务会固定源文件副本、术语范围、术语版本、领域和语言；自定义术语优先于领域提示。每批请求固定当时的服务及预设，切换服务只影响后续批次。取消、失败和退出都保留已完成区域；重试只发送未完成区域。重启只恢复任务记录，不自动调用云服务。

文本任务记录提示词版本，文件任务另记录 PDFium、LibreOffice、Vision OCR revision、操作系统和排版版本。旧的未记录版本检查点或不兼容版本不会混用当前流程继续派发；旧原文、区域结果和 PDF 仍可查看、复制、导出，用户可重新选择来源建立新任务。课堂术语需显式启用所选课程表；首次派发固定术语快照，重试不受后来编辑影响，旧检查点维持原来的无术语行为。

## 版面与覆盖说明

- 译文保持可搜索的文字层。原文字区域空间不足时，显示编号并在该源页后增加可读续页，保存一对多页映射，不无限缩小字体或截断内容。
- PDF 页面旋转和裁切通过 PDFium 页面流变换处理，保留字体与 ToUnicode 映射。双语输出直接导入原页，避免重新绘制源页造成连字乱码。
- 删除文字后，会核对图形保存前后的渲染。嵌套 Form 无法正确保存删除、色彩或裁切发生变化时，该页图形以 **300 dpi 图像**保留。结果记录实际页码与原因；这些页不声称保留矢量对象。译文文字仍可搜索，源件和双语原页保留。
- 扫描文字只在高置信度、均匀背景可采样时替换；使用实测背景色。复杂底图、低置信度文字明确列为未覆盖。公式、纯数字及图表数值保留，不能把图片保留等同于语义分析完成。
- 课件是静态页面，动画、转场、音视频不会播放。演讲者备注单独提取和显示，不混入课件正文或默认翻译。AI 助手可另行显式选择备注来源。旧 PPT 的备注经本地格式转换提取，需核对。
- 转换器以私有 Fontconfig 配置直接引用系统字体和 LibreOffice 自带字体，不复制系统商业字体。缺失的显式字体声明、受影响页面和译文管线观察到的输出字体列入报告。复杂主题继承、私有字体及特殊公式仍需逐页核对。
- 不自动下载远程图片、更新外部链接或运行宏。缺失图片、转换失败、无可提取文字和部分翻译均有独立状态，不生成空结果冒充完成。

PDF/PPT 输入上限为 200 MB、400 源页，页边长最多 4000 pt。文本或笔记正文最多 5 MB；任务最多 10000 提取区域。长表格行可按行、列编号扩展为续页。达到处理上限会明确失败并保留原件。

## 固定转换组件

| 组件 | 固定版本与来源 | 许可和本地处理 |
| --- | --- | --- |
| PDFium | 153.0.7999.0，commit `e9fc01804a0c5224ea780ad782abb8cfede628ef`；arm64，最低 macOS 13 | BSD 类许可和第三方声明；V8/XFA 关闭；本地仅调整 dylib 路径及 ad-hoc 签名 |
| LibreOffice | 官方 26.8.0.3，commit `bce0998afefdbc355585ca324285661a2170ba77`；arm64，最低 macOS 11 | 官方应用未修改；MPL-2.0 和随包 LICENSE/NOTICE、第三方字体声明 |
| ULecture helper | 项目内 Objective-C++ 源码，目标 macOS 14 | 子进程限制时间、输出和资源；私有工作目录、配置和字体缓存；禁止 IP 网络，只允许必要的本地 UNIX socket IPC |

制品 URL、SHA-256、最低系统和许可说明见 [`app/DependencyLocks/native.lock.json`](../DependencyLocks/native.lock.json)。应用将引擎及许可文件复制到自身 Resources/Conversion。

首次准备页提供“检查本地组件”和“从完整本地应用修复”。后台逐文件校验应用构建时生成的 `ConversionIntegrity.json`，包括文件内容、大小、链接及完整目录集合。修复需用户选择本机同一构建的完整 `ULecture.app`，校验后复制到应用支持目录 `UwayClassroom/ConversionRepairs/<UUID>`，再次校验并原子切换当前记录。默认继续使用包内组件；只有显式成功修复才选用受管副本。旧修复版本保留，失败或取消不替换当前记录；不联网下载、不改全局安装。校验清单自身损坏则需重新安装完整应用。每个进行中的转换固定资源位置，修复不混入已经开始的任务。

依据：[PDFium 编辑](https://pdfium.googlesource.com/pdfium/+/e9fc01804a0c5224ea780ad782abb8cfede628ef/public/fpdf_edit.h)、[页面变换](https://pdfium.googlesource.com/pdfium/+/e9fc01804a0c5224ea780ad782abb8cfede628ef/public/fpdf_transformpage.h)、[LibreOffice 参数](https://help.libreoffice.org/latest/en-US/text/shared/guide/start_parameters.html)、[转换过滤器](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)、[PDF 参数](https://help.libreoffice.org/latest/en-US/text/shared/guide/pdf_params.html)、[LibreOffice 许可](https://www.libreoffice.org/licenses/)。

## 验证边界

格式测试使用项目生成的虚构 PDF、扫描、幻灯片与笔记，网络请求使用明确标记的模拟服务。测试覆盖不等于所有真实课件或云译文语义可靠；请核对关键页面、公式和引用。实际版本的完整验证范围见 [VALIDATION.md](../../VALIDATION.md)。

组件缺失或损坏可在首次准备中从完整本地应用修复；若完整应用和校验清单均不可用，则重新安装或完整构建应用。

## BabelDOC 运行环境

`app/scripts/build-babeldoc-runtime.sh` 安装锁定的 Python 3.12.12 与 BabelDOC 0.6.4，将完整依赖、182 个离线资源及许可证放入 `Dependencies/babeldoc-runtime`，随后复制到 `.app/Contents/Resources/BabelDOC`。运行环境只在构建时下载，资源按上游 SHA3-256 校验。`requirements-hashed.lock` 锁定 Python 依赖及发行文件哈希；`runtime-manifest.json` 记录引擎、解释器、依赖与资源清单摘要。运行时使用私有可写缓存，包内资源保持只读。BabelDOC 的 AGPL-3.0 许可证及字体许可证随包保留。

验证入口：`check-babeldoc-bridge.sh`（进程与凭据边界）、`check-babeldoc-controller.sh`（任务生命周期）、Python 实际引擎本地 HTTP 模拟服务测试（不使用真实 Key，不代表账户额度或真实翻译质量）。
