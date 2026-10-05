import AppKit
import SwiftUI
import Combine
import CoreText

/// The presentation buffer is separate from the complete durable session history.
/// IDs identify a logical fragment; a revision changes it in place.
struct CaptionFragment: Equatable {
    enum State { case provisional, confirmed, partial, interrupted }
    var id: String
    var revision: Int
    var order: Int64
    var text: String
    var state: State = .confirmed
    var sourceRevision: Int? = nil
    var baseOffset: Int = 0
}

struct CaptionTrackBuffer: Equatable {
    static let maximumUTF16 = 65_536
    static let maximumFragments = 256
    private(set) var generation = UUID()
    private(set) var fragments: [CaptionFragment] = []
    private(set) var evictedThrough: Int64 = .min
    var utf16Count: Int { fragments.reduce(0) { $0 + $1.text.utf16.count } }
    mutating func reset() { fragments.removeAll(); evictedThrough = .min; generation = UUID() }
    mutating func remove(_ id: String) { fragments.removeAll { $0.id == id } }
    mutating func upsert(_ incoming: CaptionFragment) {
        guard !incoming.text.isEmpty else { remove(incoming.id); return }
        var value = incoming
        let string = value.text as NSString
        if string.length > Self.maximumUTF16 {
            let requested = string.length - Self.maximumUTF16
            let boundary = string.rangeOfComposedCharacterSequence(at: requested)
            let start = boundary.location == requested ? requested : NSMaxRange(boundary)
            value.text = string.substring(from: start); value.baseOffset += start
        }
        if let index = fragments.firstIndex(where: { $0.id == value.id }) {
            guard value.revision >= fragments[index].revision, value != fragments[index] else { return }
            fragments[index] = value
        } else {
            guard value.order > evictedThrough else { return }
            fragments.append(value); fragments.sort { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        }
        while fragments.count > Self.maximumFragments || (utf16Count > Self.maximumUTF16 && fragments.count > 1) {
            evictedThrough = max(evictedThrough, fragments.removeFirst().order)
        }
    }
}

struct CaptionVisualLine {
    let fragmentID: String
    let order: Int64
    let revision: Int
    let range: NSRange
    let text: String
    let line: CTLine
    let provisional: Bool
    var identity: String { fragmentID + ":" + String(range.location) }
}

/// Both measuring and drawing use these exact CTLine objects. There is no
/// SwiftUI Text wrapping pass and no character-count approximation of a line.
struct CaptionLayout {
    static let maximumLines = 256
    static func lines(_ fragments: [CaptionFragment], width: CGFloat, font: NSFont) -> [CaptionVisualLine] {
        var result: [CaptionVisualLine] = []
        for fragment in fragments.reversed() {
            let raw = fragment.text as NSString
            let attributed = NSAttributedString(string: fragment.text, attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var start = 0, ranges: [NSRange] = []
            while start < raw.length {
                var length = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
                if length == 0 { length = raw.rangeOfComposedCharacterSequence(at: start).length }
                ranges.append(NSRange(location: start, length: length)); start += length
                if ranges.count > maximumLines { ranges.removeFirst() }
            }
            let capacity = maximumLines - result.count
            let block = ranges.suffix(capacity).map { range in
                CaptionVisualLine(fragmentID: fragment.id, order: fragment.order, revision: fragment.revision,
                    range: NSRange(location: fragment.baseOffset + range.location, length: range.length),
                    text: raw.substring(with: range).trimmingCharacters(in: .newlines),
                    line: CTTypesetterCreateLine(typesetter, CFRange(location: range.location, length: range.length)),
                    provisional: fragment.state == .provisional)
            }
            result.insert(contentsOf: block, at: 0)
            if result.count == maximumLines { break }
        }
        return result
    }
}

private struct CaptionTrackView: NSViewRepresentable {
    var buffer: CaptionTrackBuffer
    var fontSize: Double
    var count: Int
    var color: NSColor
    var opacity: Double
    var copyTitle: String
    var accessibilityTitle: String
    func makeNSView(context: Context) -> CaptionLinesView { CaptionLinesView() }
    func updateNSView(_ view: CaptionLinesView, context: Context) {
        view.copyTitle = copyTitle; view.setAccessibilityLabel(accessibilityTitle)
        view.configure(buffer: buffer, fontSize: fontSize, count: count, color: color, opacity: opacity)
    }
}

/// Keeps at most N+2 rows in the draw loop. A new update replaces the current
/// transition instead of queuing animations behind live speech.
final class CaptionLinesView: NSView {
    private var buffer = CaptionTrackBuffer()
    private var fontSize = 24.0, lineCount = 2
    private var ink = NSColor.labelColor, inkOpacity = 1.0
    private(set) var visualLines: [CaptionVisualLine] = []
    private(set) var visibleLines: [CaptionVisualLine] = []
    private var previousWidth: CGFloat = 0
    private var cachedFragments: [String: (CaptionFragment, [CaptionVisualLine])] = [:]
    private var frontier: (order: Int64, offset: Int)?
    private var animation: Timer?
    private var animationStart = 0.0, shift = 0.0
    private var selectionStart: CGPoint?
    private var selectedText = ""
    private var selectedRows: ClosedRange<Int>?
    #if CAPTION_TESTING
    var onMeasuredLayout: ((Double) -> Void)?
    var onNativeDraw: (() -> Void)?
    #endif
    var copyTitle = "Copy"
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var lineHeight: CGFloat { ceil(fontSize * 1.3) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: lineHeight * CGFloat(lineCount)) }
    deinit { animation?.invalidate() }
    func configure(buffer next: CaptionTrackBuffer, fontSize: Double, count: Int, color: NSColor, opacity: Double) {
        let geometryChanged = self.fontSize != fontSize || lineCount != count || buffer.generation != next.generation
        let contentChanged = buffer != next
        buffer = next; self.fontSize = fontSize; lineCount = count; ink = color; inkOpacity = opacity
        if geometryChanged { frontier = nil; cachedFragments.removeAll(); invalidateIntrinsicContentSize() }
        if geometryChanged || contentChanged || visualLines.isEmpty { relayout(animate: !geometryChanged) }
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        if abs(previousWidth - bounds.width) > 0.5 { previousWidth = bounds.width; frontier = nil; cachedFragments.removeAll(); relayout(animate: false) }
    }
    private func relayout(animate: Bool) {
        #if CAPTION_TESTING
        let measuredStart = ProcessInfo.processInfo.systemUptime
        defer { onMeasuredLayout?((ProcessInfo.processInfo.systemUptime - measuredStart) * 1000) }
        #endif
        let oldVisible = visibleLines
        selectedRows = nil; selectedText = ""
        previousWidth = bounds.width
        var nextLines: [CaptionVisualLine] = [], nextCache: [String: (CaptionFragment, [CaptionVisualLine])] = [:]
        for fragment in buffer.fragments.reversed() {
            let cached = cachedFragments[fragment.id]
            let capacity = CaptionLayout.maximumLines - nextLines.count
            let cachedTailIsEnough = cached.map { $0.1.count >= capacity || $0.1.first?.range.location == fragment.baseOffset } ?? false
            let lines = cached?.0 == fragment && cachedTailIsEnough ? cached!.1 : CaptionLayout.lines([fragment], width: bounds.width, font: .systemFont(ofSize: fontSize, weight: .medium))
            let retained = Array(lines.suffix(capacity))
            nextLines.insert(contentsOf: retained, at: 0); nextCache[fragment.id] = (fragment, retained)
            if nextLines.count == CaptionLayout.maximumLines { break }
        }
        visualLines = nextLines; cachedFragments = nextCache
        // A correction can shorten the currently visible fragment. Clamp its
        // character anchor within that fragment rather than showing an empty
        // viewport or resurrecting earlier fragments that have already left.
        let anchoredOffset = frontier.map { anchor in
            min(anchor.offset, visualLines.last(where: { $0.order == anchor.order })?.range.location ?? anchor.offset)
        }
        let eligible = visualLines.filter { line in
            guard let frontier else { return true }
            return line.order > frontier.order || (line.order == frontier.order && line.range.location >= (anchoredOffset ?? frontier.offset))
        }
        visibleLines = Array(eligible.suffix(lineCount))
        // Establish an eviction frontier only after a row actually leaves the
        // viewport. A late earlier translation can still fill unused rows; the
        // first received fragment must not silently exclude unseen context.
        if eligible.count > lineCount || frontier != nil, let first = visibleLines.first { frontier = (first.order, first.range.location) }
        animation?.invalidate(); animation = nil; shift = 0
        if animate, !reduceMotion(),
           let oldLast = oldVisible.last, let oldIndex = visualLines.firstIndex(where: { $0.identity == oldLast.identity }),
           let last = visibleLines.last, let newIndex = visualLines.firstIndex(where: { $0.identity == last.identity }), newIndex > oldIndex {
            // Only two outgoing rows are retained for painting. Cap a burst's
            // cosmetic displacement to that guard band, so large revisions do
            // not reveal an empty gap while catching up to the newest lines.
            shift = Double(min(lineCount, min(2, newIndex - oldIndex))) * lineHeight
            animationStart = ProcessInfo.processInfo.systemUptime
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.needsDisplay = true
                if ProcessInfo.processInfo.systemUptime - self.animationStart >= 0.15 { timer.invalidate(); self.animation = nil; self.shift = 0 }
            }
        }
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityValue(visibleLines.map(\.text).joined(separator: "\n"))
        needsDisplay = true
    }
    var presentationEvidence: [[String: Any]] {
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - animationStart) / 0.15))
        let displacement = reduceMotion() ? 0 : shift * pow(1 - progress, 3)
        return visibleLines.enumerated().map { index, line in
            ["id": line.identity, "text": line.text, "offset": line.range.location, "y": Double(index) * lineHeight + displacement, "lineHeight": lineHeight]
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let first = visibleLines.first,
              let start = visualLines.firstIndex(where: { $0.identity == first.identity }) else { return }
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - animationStart) / 0.15))
        let displacement = reduceMotion() ? 0 : shift * pow(1 - progress, 3)
        context.saveGState(); context.clip(to: bounds)
        let begin = max(0, start - 2), end = min(visualLines.count, start + lineCount)
        for index in begin..<end {
            let value = visualLines[index]
            let y = CGFloat(index - start) * lineHeight + displacement
            if selectedRows?.contains(index - start) == true {
                context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).cgColor)
                context.fill(CGRect(x: 0, y: y, width: bounds.width, height: lineHeight))
            }
            context.saveGState(); context.translateBy(x: 0, y: y + fontSize)
            context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
            context.setAlpha(inkOpacity * (value.provisional ? 0.68 : 1))
            // Color is a drawing attribute on the same glyph runs, with no reflow.
            context.setFillColor(ink.cgColor)
            CTLineDraw(value.line, context)
            context.restoreGState()
        }
        context.restoreGState()
        #if CAPTION_TESTING
        onNativeDraw?()
        #endif
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); selectionStart = convert(event.locationInWindow, from: nil); selectedText = ""; selectedRows = nil; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { updateSelection(with: event) }
    override func mouseUp(with event: NSEvent) { updateSelection(with: event); selectionStart = nil }
    private func updateSelection(with event: NSEvent) {
        guard let start = selectionStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let low = max(0, Int(min(start.y, end.y) / lineHeight)), high = min(visibleLines.count - 1, Int(max(start.y, end.y) / lineHeight))
        if low <= high { selectedRows = low...high; selectedText = visibleLines[low...high].map(\.text).joined(separator: "\n"); needsDisplay = true }
    }
    @objc func copy(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText.isEmpty ? visibleLines.map(\.text).joined(separator: "\n") : selectedText, forType: .string) }
    override func menu(for event: NSEvent) -> NSMenu? { let menu = NSMenu(); menu.addItem(withTitle: copyTitle, action: #selector(copy(_:)), keyEquivalent: ""); return menu }
}

struct SubtitlePreferences: Codable, Equatable {
    var fontSize = 24.0
    var sourceLines = 2
    var translationLines = 2
    var translationFirst = false
    var alwaysOnTop = true
    var red = 0.08, green = 0.08, blue = 0.08, opacity = 0.86
    var x = 160.0, y = 120.0, width = 760.0, height = 200.0
    func normalized() -> Self {
        var p = self
        p.fontSize = fontSize.isFinite ? min(72, max(12, fontSize)) : 24
        p.sourceLines = min(8, max(0, sourceLines)); p.translationLines = min(8, max(0, translationLines))
        if p.sourceLines == 0 && p.translationLines == 0 { p.translationLines = 1 }
        p.red = red.isFinite ? min(1, max(0, red)) : 0.08
        p.green = green.isFinite ? min(1, max(0, green)) : 0.08
        p.blue = blue.isFinite ? min(1, max(0, blue)) : 0.08
        p.opacity = opacity.isFinite ? min(1, max(0, opacity)) : 0.86
        p.width = width.isFinite ? min(5000, max(320, width)) : 760
        p.height = height.isFinite ? min(3000, max(120, height)) : 200
        if !p.x.isFinite { p.x = 160 }; if !p.y.isFinite { p.y = 120 }
        return p
    }
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeMain: Bool { false }
    override var canBecomeKey: Bool { true }
}

/// This object has no audio/session control reference. Closing its panel cannot
/// pause, end, create, or resume a capture session.
@MainActor final class SubtitlePanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var preferences: SubtitlePreferences
    @Published private(set) var isVisible = false
    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var sourceBuffer = CaptionTrackBuffer()
    @Published private(set) var translationBuffer = CaptionTrackBuffer()
    @Published var language = "en"
    private(set) var panel: NSPanel?
    private let defaults: UserDefaults
    private var screenObserver: NSObjectProtocol?
    private let key = "ulecture.subtitle-preferences.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = (defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SubtitlePreferences.self, from: $0) } ?? SubtitlePreferences()).normalized()
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.constrainToScreens() }
        }
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    func update(_ change: (inout SubtitlePreferences) -> Void) {
        let previous = preferences
        var value = preferences; change(&value); preferences = value.normalized()
        defaults.set(try? JSONEncoder().encode(preferences), forKey: key)
        panel?.level = preferences.alwaysOnTop ? .floating : .normal
        if previous.fontSize != preferences.fontSize || previous.sourceLines != preferences.sourceLines || previous.translationLines != preferences.translationLines { fitConfiguredLines() }
    }
    func resetCaptions() { sourceBuffer.reset(); resetTranslations(); sourceText = "" }
    func resetTranslations() { translationBuffer.reset(); translatedText = "" }
    func updateFragment(_ fragment: CaptionFragment, translation: Bool = false) {
        if translation { var next = translationBuffer; next.upsert(fragment); if next != translationBuffer { translationBuffer = next }; let text = next.fragments.last?.text ?? ""; if translatedText != text { translatedText = text } }
        else { var next = sourceBuffer; next.upsert(fragment); if next != sourceBuffer { sourceBuffer = next }; let text = next.fragments.last?.text ?? ""; if sourceText != text { sourceText = text } }
    }
    func removeFragment(_ id: String, translation: Bool = false) {
        if translation { var next = translationBuffer; next.remove(id); if next != translationBuffer { translationBuffer = next }; translatedText = next.fragments.last?.text ?? "" }
        else { var next = sourceBuffer; next.remove(id); if next != sourceBuffer { sourceBuffer = next }; sourceText = next.fragments.last?.text ?? "" }
    }
    /// Static preview compatibility. Production sends stable fragments.
    func display(source: String, translation: String) {
        updateFragment(CaptionFragment(id: "preview-source", revision: 0, order: 0, text: source))
        updateFragment(CaptionFragment(id: "preview-translation", revision: 0, order: 0, text: translation), translation: true)
    }
    func show() {
        if panel == nil {
            let window = SubtitlePanel(contentRect: preferences.frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ULecture"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isFloatingPanel = true; window.hidesOnDeactivate = false; window.becomesKeyOnlyIfNeeded = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.isMovableByWindowBackground = true; window.minSize = NSSize(width: 320, height: 120)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: SubtitleContent(controller: self))
            panel = window
        }
        panel?.level = preferences.alwaysOnTop ? .floating : .normal
        fitConfiguredLines(); constrainToScreens(); panel?.orderFrontRegardless(); isVisible = true
    }
    func hide() { panel?.orderOut(nil); isVisible = false }
    func dispose() {
        hide(); panel?.contentView = nil; panel?.delegate = nil; panel?.close(); panel = nil
    }
    func toggle() { isVisible ? hide() : show() }
    func windowWillClose(_ notification: Notification) { isVisible = false }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    private func saveFrame() {
        guard let frame = panel?.frame else { return }
        update { $0.x = frame.minX; $0.y = frame.minY; $0.width = frame.width; $0.height = frame.height }
    }
    static func constrainedFrame(_ proposed: CGRect, screens: [CGRect]) -> CGRect {
        let available = screens.isEmpty ? [CGRect(x: 0, y: 0, width: 1024, height: 768)] : screens
        let screen = available.max { a, b in
            let x = a.intersection(proposed), y = b.intersection(proposed)
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        } ?? available[0]
        let width = min(max(320, proposed.width), screen.width), height = min(max(120, proposed.height), screen.height)
        return CGRect(x: min(max(proposed.minX, screen.minX), screen.maxX - width), y: min(max(proposed.minY, screen.minY), screen.maxY - height), width: width, height: height)
    }
    func constrainToScreens() {
        let frame = Self.constrainedFrame(panel?.frame ?? preferences.frame, screens: NSScreen.screens.map(\.visibleFrame))
        panel?.setFrame(frame, display: true)
        update { $0.x = frame.minX; $0.y = frame.minY; $0.width = frame.width; $0.height = frame.height }
    }
    private func fitConfiguredLines() {
        guard let panel else { return }
        let available = panel.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 768
        let minimum = min(available, 98 + Double(preferences.sourceLines + preferences.translationLines) * ceil(preferences.fontSize * 1.3))
        panel.minSize = NSSize(width: 320, height: minimum)
        if panel.frame.height < minimum {
            var frame = panel.frame; frame.origin.y -= minimum - frame.height; frame.size.height = minimum
            panel.setFrame(frame, display: true)
        }
    }
}

private struct SubtitleContent: View {
    @ObservedObject var controller: SubtitlePanelController
    private var p: SubtitlePreferences { controller.preferences }
    private var ink: Color { p.red * 0.2126 + p.green * 0.7152 + p.blue * 0.0722 > 0.6 ? .black : .white }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("ULecture").font(.caption.weight(.medium)); Spacer(); Text(InterpretationText.text("captionsIndependent", language: controller.language)).font(.caption2) }.opacity(0.7)
            if p.translationFirst { translation; source } else { source; translation }
            if controller.sourceText.isEmpty && controller.translatedText.isEmpty { Text(InterpretationText.text("captionWaiting", language: controller.language)).font(.system(size: p.fontSize)).opacity(0.6) }
            Spacer(minLength: 0)
        }
        .font(.system(size: p.fontSize, weight: .medium)).foregroundStyle(ink)
        .padding(.horizontal, 18).padding(.top, 30).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: p.red, green: p.green, blue: p.blue).opacity(p.opacity))
    }
    @ViewBuilder private var source: some View {
        if p.sourceLines > 0 && !controller.sourceText.isEmpty { CaptionTrackView(buffer: controller.sourceBuffer, fontSize: p.fontSize, count: p.sourceLines, color: NSColor(ink), opacity: 0.8, copyTitle: InterpretationText.text("copy", language: controller.language), accessibilityTitle: InterpretationText.text("sourceLines", language: controller.language)).frame(height: ceil(p.fontSize * 1.3) * Double(p.sourceLines)) }
    }
    @ViewBuilder private var translation: some View {
        if p.translationLines > 0 && !controller.translatedText.isEmpty { CaptionTrackView(buffer: controller.translationBuffer, fontSize: p.fontSize, count: p.translationLines, color: NSColor(ink), opacity: 1, copyTitle: InterpretationText.text("copy", language: controller.language), accessibilityTitle: InterpretationText.text("translatedLines", language: controller.language)).frame(height: ceil(p.fontSize * 1.3) * Double(p.translationLines)) }
    }
}

struct SubtitlePreferencesView: View {
    @ObservedObject var controller: SubtitlePanelController
    let language: String
    private func t(_ key: String) -> String { InterpretationText.text(key, language: language) }
    private func binding<T>(_ key: WritableKeyPath<SubtitlePreferences, T>) -> Binding<T> {
        Binding(get: { controller.preferences[keyPath: key] }, set: { value in controller.update { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(t("alwaysOnTop"), isOn: binding(\.alwaysOnTop))
            HStack { Text(t("fontSize")); Slider(value: binding(\.fontSize), in: 12...72, step: 1); Text("\(Int(controller.preferences.fontSize))").monospacedDigit() }
            Stepper(t("sourceLines") + ": \(controller.preferences.sourceLines)", value: binding(\.sourceLines), in: 0...8)
            Stepper(t("translatedLines") + ": \(controller.preferences.translationLines)", value: binding(\.translationLines), in: 0...8)
            Toggle(t("translationFirst"), isOn: binding(\.translationFirst))
            ColorPicker(t("background"), selection: Binding(get: { Color(red: controller.preferences.red, green: controller.preferences.green, blue: controller.preferences.blue) }, set: { color in
                if let value = NSColor(color).usingColorSpace(.deviceRGB) { controller.update { $0.red = value.redComponent; $0.green = value.greenComponent; $0.blue = value.blueComponent } }
            }), supportsOpacity: false)
            HStack { Text(t("opacity")); Slider(value: binding(\.opacity), in: 0...1); Text("\(Int(controller.preferences.opacity * 100))%").monospacedDigit() }
            Text(t("captionsIndependent")).font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 340)
    }
}

/// Dedicated tool labels are complete in all four supported interface languages.
/// Shared labels and known diagnostics continue through the common localizer.
enum InterpretationText {
    static let labels: [String: [String]] = [
        "configurationPauses": ["更改音源、语言或录音设置后保持暂停；请手动继续。", "更改音源、語言或錄音設定後保持暫停；請手動繼續。", "Changing the input, language or recording setting pauses capture. Resume when ready.", "入力元・言語・録音設定を変更すると一時停止します。準備できたら手動で再開してください。"],
        "deviceUnavailable": ["已选设备当前不可用", "所選裝置目前無法使用", "Selected device unavailable", "選択したデバイスを使用できません"],
        "translationControls": ["翻译与普通话播报", "翻譯與普通話播報", "Translation and Mandarin speech", "翻訳と中国語読み上げ"],
        "newInterpretation": ["新建同传", "新增同傳", "New interpretation", "新しい同時通訳"],
        "sessions": ["同传记录", "同傳記錄", "Interpretation sessions", "同時通訳の記録"],
        "noSession": ["开始后建立独立同传记录，无需课程。", "開始後建立獨立同傳記錄，無需課程。", "Start an independent session without a course.", "コースなしで独立したセッションを開始できます。"],
        "showCaptions": ["显示字幕", "顯示字幕", "Show captions", "字幕を表示"],
        "hideCaptions": ["关闭字幕", "關閉字幕", "Hide captions", "字幕を閉じる"],
        "captionSettings": ["字幕设置", "字幕設定", "Caption settings", "字幕設定"],
        "captionsIndependent": ["关闭字幕不停止同传", "關閉字幕不停止同傳", "Closing captions keeps the session running", "字幕を閉じてもセッションは継続します"],
        "captionWaiting": ["等待已保存的原文或译文", "等待已儲存的原文或譯文", "Waiting for saved transcript or translation", "保存された原文または翻訳を待っています"],
        "alwaysOnTop": ["置顶", "置頂", "Always on top", "最前面に表示"],
        "fontSize": ["字号", "字級", "Font size", "文字サイズ"],
        "sourceLines": ["原文行数", "原文行數", "Source lines", "原文の行数"],
        "translatedLines": ["译文行数", "譯文行數", "Translation lines", "翻訳の行数"],
        "translationFirst": ["译文在上", "譯文在上", "Translation above source", "翻訳を上に表示"],
        "background": ["背景色", "背景色", "Background", "背景色"],
        "opacity": ["背景不透明度", "背景不透明度", "Background opacity", "背景の不透明度"],
        "associateCourse": ["关联课程", "關聯課程", "Link to course", "コースに関連付け"],
        "standalone": ["独立同传", "獨立同傳", "Independent interpretation", "独立した同時通訳"],
        "translationPaused": ["暂停翻译", "暫停翻譯", "Pause translation", "翻訳を一時停止"],
        "translationResume": ["继续翻译与补译", "繼續翻譯與補譯", "Resume translation and backlog", "翻訳と未処理分を再開"],
        "retrySave": ["重试保存", "重試儲存", "Retry saving", "保存を再試行"],
        "recordingNotAvailable": ["该时间未保存录音，无法回听。", "該時間未儲存錄音，無法回聽。", "No recording was saved at this time.", "この時刻の録音は保存されていません。"],
        "pauseBeforeSwitch": ["请先暂停并等待保存后切换记录。", "請先暫停並等待儲存後切換記錄。", "Pause and wait for saving before switching sessions.", "セッションを切り替える前に一時停止して保存を待ってください。"],
        "sessionSaveFailed": ["有内容尚未保存，请先重试保存。", "有內容尚未儲存，請先重試儲存。", "Some content is unsaved. Retry saving first.", "未保存の内容があります。保存を再試行してください。"],
        "transcriptLocationMissing": ["转写保存位置不可用，请在设置中重新定位。", "轉寫儲存位置無法使用，請在設定中重新定位。", "Transcript location unavailable. Relocate it in Settings.", "文字起こしの保存先が使用できません。設定で再指定してください。"],
        "sessionEnded": ["同传已结束；请新建记录。", "同傳已結束；請新增記錄。", "This session has ended. Create a new one.", "セッションは終了しました。新しく作成してください。"],
        "translationWaiting": ["等待译文", "等待譯文", "Waiting for translation", "翻訳を待っています"],
        "stopVoice": ["停止播报", "停止播報", "Stop speech", "読み上げを停止"],
        "enableVoice": ["开启普通话播报", "開啟普通話播報", "Enable Mandarin speech", "中国語読み上げを有効にする"],
        "saveRecording": ["保存录音", "儲存錄音", "Save recording", "録音を保存"],
        "targetChinese": ["中文译文", "中文譯文", "Chinese translation", "中国語訳"],
        "retryTranslation": ["重试翻译", "重試翻譯", "Retry translation", "翻訳を再試行"],
        "gap": ["未采集或未转写区间", "未擷取或未轉寫區間", "Uncaptured or untranscribed interval", "収録・文字起こしされていない区間"],
        "playFromHere": ["从此处回听", "從此處回聽", "Play from here", "ここから再生"],
        "pausePlayback": ["暂停回听", "暫停回聽", "Pause playback", "再生を一時停止"],
        "resumePlayback": ["继续回听", "繼續回聽", "Resume playback", "再生を再開"],
        "stopPlayback": ["停止回听", "停止回聽", "Stop playback", "再生を停止"],
        "startInterpretation": ["开始同传", "開始同傳", "Start interpretation", "同時通訳を開始"],
        "endInterpretation": ["结束同传", "結束同傳", "End interpretation", "同時通訳を終了"]
    ]
    static func text(_ key: String, language: String) -> String {
        if let values = labels[key] { return values[["zh-Hans": 0, "zh-Hant": 1, "en": 2, "ja": 3][language] ?? 2] }
        let shared = Localizer.string(key, language: language)
        return shared == key ? StatusLocalizer.detail(key, language: language) : shared
    }
}
