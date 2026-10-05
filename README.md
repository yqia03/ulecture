<p align="center"><img src="assets/brand/ulecture-icon.png" width="144" alt="ULecture 应用图标"></p>

# ULecture

把课堂资料、听课理解和学习记录连接起来。

原生 macOS 学习工作空间：整理课程资料，阅读与批注课件，记录笔记，使用实时转写、翻译和 AI 助手。界面支持简体中文、繁体中文、English 和日本語，以及浅色、深色主题。

[下载](https://github.com/yqia03/ulecture/releases/latest) · [使用指南](docs/ulecture/user-guide.md) · [English](README.en.md) · [问题反馈](https://github.com/yqia03/ulecture/issues)

[![ULecture 介绍](assets/media/cover.jpg)](https://github.com/yqia03/ulecture/releases/download/v1.1.0/ULecture-introduction.mp4)

![连续逐行字幕预览](assets/media/preview.gif)

完整介绍片使用原创纯器乐音乐与中英文双语字幕，无旁白、演唱或哼唱。画面保留真实应用操作和连续逐行字幕，课程与文字均为专门制作的虚构演示资料。[音乐、字幕与可复现工程](media/README.md)。

## 可以做什么

- **课程与资料**：导入 PDF、PPT/PPTX、Markdown、TXT，创建文件夹及笔记。课程目录由应用管理，未知文件不会自动载入。
- **阅读与记录**：PDF 阅读、批注及导出；块笔记支持文字、列表、表格、图片及历史版本。PPT 在本机转换为静态阅读 PDF，保留原件。
- **课堂与独立同传**：本地识别加在线文本翻译，以及 Google、OpenAI 在线同传。字幕按实际视觉行连续滚动，可分别设置原译文行数、顺序、颜色、字号和透明度。
- **两份自动 TXT**：每个会话持续保存纯原文 `transcript.txt` 与原文加译文的 `transcript-bilingual.txt`。同传页面提供两个 Finder 定位入口。
- **学习辅助**：选择资料后提问、解释选区、生成笔记或总结；来源和版本可回看。文本及文档翻译可单独配置服务。
- **数据管理**：本地存储、可恢复删除、导出、保存位置迁移及备份恢复。无 ULecture 账号、云同步或订阅。

## 界面一览

![课程阅读与笔记](assets/media/workspace.jpg)

![块笔记与学习记录](assets/media/notes.jpg)

## 系统与安装

构建目标为 **Apple Silicon、macOS 14 或更新版本**。Intel 不在当前发行范围。本次实际测试机器和系统见 [验证报告](VALIDATION.md)；最低系统及 M1/8 GB 不应被理解为已经实机验证。

1. 在 [Release](https://github.com/yqia03/ulecture/releases/latest) 下载应用压缩包或 DMG，并核对同页 SHA-256 校验文件。
2. 将 `ULecture.app` 放入“应用程序”，再打开。
3. 本发行包采用临时签名，**没有 Developer ID 签名或 Apple 公证**。macOS 可能阻止首次打开；确认来源与校验值后，按 [Apple 官方说明](https://support.apple.com/en-us/102445)中“隐私与安全性”的“仍要打开”流程处理，或自行从源码构建。不要关闭系统安全保护。
4. 首次使用本地转写时准备离线模型；开始采集时才申请所需的麦克风或屏幕与系统音频录制权限。打开应用本身不会采集音频。

发行包包含离线识别模型和本地文件转换运行环境，体积较大。使用本地阅读、笔记、转写不需要云服务 Key；翻译与 AI 功能需要自行配置账户，服务商可能收费。

## 首次设置与服务

在设置中分别配置“AI 服务”“文本翻译服务”“文档翻译服务”。支持 Google Gemini AI Studio、DeepSeek、OpenAI 和 OpenAI 兼容接口。兼容服务还需要 Base URL；可主动选择让文本或文档服务跟随 AI 服务。

Key 保存在 macOS 钥匙串。保存或切换服务不会自动测试连接；点击测试才会发送请求。在线同传使用对应 Google/OpenAI 实时服务，模型、区域、账户及费用限制以服务商实际可用性为准。标为 Preview 的提供商模型继续保留该标识。

本地识别主要面向英语、日语课堂；噪声、口音、专有名词和重叠发言会影响结果。AI 内容可能出错，请结合原始课件核对。离线转写不等于离线翻译；在线模式会将所选音源发送给服务商。

## TXT、字幕与数据

- 两份 TXT 来自同一已保存会话状态。翻译未完成时仍保留原文，正确译文到达后补入；修订不会不断追加重复段落。
- 原译文缺乏可靠关联的在线字幕按独立轨道及真实顺序记录，不虚构逐句对应。未完成或中断状态会作简短标记。
- 文件自动持续更新，无需手动导出。第二份写入失败时会显示保存未完成，并保留恢复依据；点击重试或重启后恢复。
- 字幕行数指按当前宽度和字号排出的视觉行。四行窗口新增一行时，仅最上面一行离开；原文和译文分别自然换行。
- 默认会话目录为 `~/Documents/ULecture/Transcripts`；实际路径显示在设置。课程和索引位于 `~/Library/Application Support/ULecture`。模型沿用旧版兼容路径，详见[数据指南](docs/ulecture/user-guide.md)。
- 旧双语 `transcript.txt` 转换前保留原始恢复副本；数据库无法可靠恢复时不会用空文件覆盖旧内容。升级前仍建议创建备份。

[隐私与网络行为](PRIVACY.md) · [文件格式与转换限制](app/docs/CONVERSION.md)

## 开发与许可

使用 Xcode 命令行工具及项目锁定依赖构建，详见 [BUILDING.md](BUILDING.md)。源码、测试、构建脚本和资源锁进入 Git；模型、运行时、大型构建与私人数据不进入历史。

ULecture 自有源码以 **AGPL-3.0-only** 发布，见 [LICENSE](LICENSE)。第三方组件、模型、字体和媒体保留各自许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)。分发包的对应源码与构建清单位于同版本 Release。

[更新记录](CHANGELOG.md) · [验证范围](VALIDATION.md) · [媒体生成工程](media/README.md)

反馈问题时请说明版本、系统、操作步骤及错误提示。不要提交 API Key、真实课程、录音、转写、个人路径或未经清理的日志。
