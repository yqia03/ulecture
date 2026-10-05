# ULecture 宣传片工程 / Promotional film project

75 秒、1920×1080、30 fps、H.264/AAC。使用原创电子纯音乐《Connections》，没有旁白、演唱、哼唱或其他人声；每段介绍同时显示简体中文和英文。课程、笔记和会话均为原创虚构演示资料。

The 75-second film combines actual native application footage with Chinese and English titles and original instrumental electronic music. No voice is included. The caption sequence preserves 600 consecutive frames from the actual production caption panel.

## 文件

- `timeline.json`：镜头入点、双语标题及字幕段时间线。
- `render-video.py`：Pillow 排版与 FFmpeg 编码；字幕界面像素来自原生素材。
- `sanitize-capture.py`：仅遮蔽演示工作区的绝对路径行，并逐帧验证遮蔽区域外的 RGB 像素完全一致。
- `generate-music.py`：确定性的原创纯器乐合成与两遍响度处理，不依赖音色库或网络服务。
- `music-license.md`：作者、来源、授权范围、分发与署名要求。
- `archive-project.py`：依据明确白名单打包、生成内部 SHA-256 清单，并拒绝私人路径或旧配音输入。
- `render-requirements.lock`：渲染需要的两个 Python 包及固定版本。
- `generate-audio-fixtures.py`、`fixture-voice-model.lock.json`、`fixture-voice-en-model.lock.json`、`requirements.lock`：开发测试使用的虚构日语／英语语音夹具及其独立环境；**不参与宣传片，音轨不进入媒体包**。

同版本 Release 的媒体工程归档提供经过路径脱敏的原生 UI 片段、捕获事件清单、字体及许可、独立音乐 WAV、乐谱事件表、字幕文件和全部合成脚本。源码仓库只保留小体积封面、GIF、截图与脚本；不提交模型权重或完整视频。

## 从媒体工程归档重建

需要 Python 3.13 与 FFmpeg（含 libx264、AAC、loudnorm）；实际制作使用 Python 3.13.13 和 FFmpeg 9.0.1。安装工具本身时遵循各自许可证；工程不捆绑 FFmpeg。解压工程后，在其目录执行：

```sh
python3 -m venv .media-env
.media-env/bin/pip install -r media/render-requirements.lock
.media-env/bin/python media/generate-music.py --output output
.media-env/bin/python media/render-video.py \
  --capture media-input/actual-ui-continuous.mp4 \
  --music output/ULecture-music.wav \
  --font fonts/SourceHanSansCN-Regular.ttf \
  --output output
.media-env/bin/python media/package-previews.py --output output
.media-env/bin/python media/validate-media.py --output output \
  --capture media-input/actual-ui-continuous.mp4
```

`--repository` 可覆盖片尾链接，`--still 40` 可先检查单帧。生成的三个 UTF-8 SRT 分别为中文、英文及中英双语；成片已内嵌双语图层，无需播放器外挂字幕。脚本会拒绝出画面的文字；最终仍应检查实际画面。包版本和工具版本相同可以复现制作过程；不同 FFmpeg 构建的压缩字节可能不同。

`package-previews.py` 从最终 MP4 生成封面、README GIF、关键截图和逐镜头检查图。`validate-media.py` 完整解码视频，核对 1080p30/75 秒、音频、字幕、连续字幕像素映射及预览；它不代替完整播放和实际聆听。

## 从应用重新捕获

先依照根目录 `BUILDING.md` 准备应用依赖。运行：

```sh
capture_root="$(mktemp -d)"
bash app/scripts/capture-promo-ui.sh "$capture_root/output" "$capture_root/workspace"
```

捕获器使用独立虚构工作空间和实际 SwiftUI/AppKit 视图，演示 PDF 阅读、原生笔记输入和生产字幕面板。PDFKit 异步 tile 使用同一 PDFPage、相同缩放及滚动位置补入对应区域。字幕原译文由夹具按时间送入；这些画面不是实际麦克风采集、真实云服务或性能测量。升级后的捕获必须重新核对裁剪坐标、时间线和逐帧映射。

公开工程中的 `actual-ui-continuous.mp4` 已对 38–68 秒画面中的虚构临时工作区路径行作中性遮蔽。未遮蔽原片仅保留在本地私人恢复目录；不会进入工程归档。该操作不遮挡按钮、字幕或其他功能内容。它使用无损 RGB H.264，并验证全部 2,250 帧：矩形 `(x=390, y=363, width=1290, height=35)` 以外的像素逐字节保持一致。`capture-redaction.json` 记录原片、干净片段及脚本的 SHA-256。

对坐标和时序相同的新捕获，可在剪辑前运行下列命令；更改捕获布局后必须先重新核对位置：

```sh
python media/sanitize-capture.py --input native-capture.mp4 \
  --output clean-capture.mp4 --report capture-redaction.json
```

本版最终剪辑使用的全窗片段早于遮蔽时间，双 TXT 裁剪底边为 y=361，字幕裁剪顶边为 y=478，因此所用像素均未变化。现有 MP4 无需重新编码；连续 600 帧字幕映射已使用干净片段重新验证。工程重建直接使用包内干净片段，不需要私人原片。

The distributed native capture masks only a fictional temporary workspace path row. Lossless RGB verification confirms that all other pixels in all 2,250 frames are unchanged. The final edit uses no pixels from that row, and its 600 consecutive caption frames are revalidated against the sanitized input. Rebuilding the film uses the included clean capture; the unredacted recovery copy is not distributed.

## 音乐与展示边界

《Connections》从数学振荡器和固定种子的噪声合成，包含完整音符事件表，没有第三方歌曲、采样或声音模型。工程对 75 秒音轨做两遍 loudnorm，目标 −20 LUFS、真峰值不高于 −2 dBTP，开头淡入 2.1 秒、结尾淡出 4 秒；不使用音频片段突兀循环。最终 AAC 另行测量，结果以报告为准。

图标复用 `assets/brand` 的正式项目图标。项目自有素材和音乐按根目录 `COPYRIGHT` 适用 AGPL-3.0-only；Source Han Sans CN 字体按自身 OFL 许可。原生界面中显示的系统字体不另行打包。

片尾指向项目仓库；公开前该地址仅为拟发布位置，不代表仓库已存在。宣传片仅描述已实现的产品行为，服务延迟、质量、费用和可用性取决于使用者选择的识别与翻译服务。README 的 GIF 静音，完整 MP4 带纯音乐。

## 独立的开发语音夹具

这部分只供 ASR 回归测试，**不是宣传片工程的输入**，也不进入媒体 ZIP。使用 `requirements.lock` 单独准备语音生成环境；日语分词另需该锁中 UniDic 包的数据。两种语言使用不同锁：

- 日语：`hexgrad/Kokoro-82M`，`jf_alpha`，固定 revision 和哈希见 `fixture-voice-model.lock.json`。
- 英语：`hexgrad/Kokoro-82M-v1.1-zh`，以英语管线 `lang_code=a` 和 `zf_001` 预设制作，固定 revision 和哈希见 `fixture-voice-en-model.lock.json`。模型名称中的 zh 不代表输出语言；保留这份锁是为了说明已提交英语夹具的真实生成来源。

两者模型许可为 Apache-2.0，全文见 `licenses/Kokoro-Apache-2.0.txt`。测试正文读取并校验 `app/Tests/Fixtures/Audio` 中已提交的虚构文本，输出必须使用单独目录，避免覆盖正在使用的回归材料：

```sh
python media/generate-audio-fixtures.py --language en --cache .media-cache/fixture-en --output fixture-output/en
python media/generate-audio-fixtures.py --language ja --cache .media-cache/fixture-ja --output fixture-output/ja
```

生成器不修改模型锁。公开夹具本身的 SHA-256 在 `app/Tests/Fixtures/Audio/manifest.json`；FLAC 容器字节可能随编码器改变，重建时还应比较解码后的 PCM，不宣称跨工具版本逐字节一致。

已有本地模型时，可加 `--sample --offline`，在禁止网络的环境中只合成第一句作快速检查；文件名带 `-sample`，不冒充完整回归夹具。
