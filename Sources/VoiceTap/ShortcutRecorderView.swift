import Carbon.HIToolbox
import Cocoa

// MARK: - C 回调
//
// 必须是文件级 nonisolated 函数，不能写成闭包字面量：Swift 6 会把方法内的
// 闭包推断为 MainActor 隔离，@convention(c) thunk 里会被注入 executor 检查，
// 事件回调重入时可能 EXC_BAD_ACCESS。

private func shortcutRecorderTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let view = Unmanaged<ShortcutRecorderView>.fromOpaque(refcon).takeUnretainedValue()

    // 系统会因超时或用户输入禁用 tap，禁用后必须重新启用，否则录制静默失效
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        view.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    view.handleTapEvent(keyCode: keyCode, flags: event.flags, isKeyDown: type == .keyDown)

    // 录制期间吞掉按键，否则录 ⌘Q 会退出 app、录 ⌘W 会关窗口
    return nil
}

/// 快捷键录制控件。点一下开始录，按下想要的组合键即完成。
///
/// **走 CGEventTap 而不是 NSEvent**：fn（🌐）键在到达应用的 responder chain
/// 之前就被系统消费掉了（用于切换输入法 / Emoji / 听写），`NSView.flagsChanged`
/// 永远等不到它——实测按 fn 时视图一条事件都收不到。EventTap 在更底层，
/// 能拿到 `keyCode=63 flags=fn`。输入法能录 fn 也是同一个道理。
///
/// 必须同时支持两种形态，因为输入法两种都允许：
///   - **纯修饰键**（如单独一个 fn）—— 只有 flagsChanged，永远没有 keyDown
///   - **修饰键 + 主键**（如 ⌃⌥⌘Z）—— 以 keyDown 结束
@MainActor
final class ShortcutRecorderView: NSView {

    var onChange: ((Shortcut) -> Void)?

    private(set) var shortcut: Shortcut {
        didSet { needsDisplay = true }
    }

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    /// 录制纯修饰键时，按下的那一刻还不知道用户会不会接着按主键。
    /// 先记下来，等修饰键全部松开仍无主键，才认定是纯修饰键组合。
    private var pendingModifiers: UInt64 = 0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 录制期间 tap 会吞掉所有按键。任何让录制状态卡住的路径都等于
    /// **键盘失灵**，所以必须有超时兜底 —— 这跟触发键卡在按下状态是同一类风险。
    private var timeoutTimer: Timer?
    private static let recordingTimeout: TimeInterval = 10

    private let clearButton = NSButton()

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "清除")
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 视图脱离窗口时必须停录。
    ///
    /// 不能靠 deinit：它不在 MainActor 上，碰不到 eventTap。而一个还活着的 tap
    /// 会**继续吞掉全系统的按键** —— 键盘直接失灵，且用户完全想不到是这里造成的。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopRecording() }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        if isRecording {
            text = pendingModifiers == 0
                ? "请按下快捷键…"
                : Shortcut(keyCode: nil, modifiers: pendingModifiers).displayString
        } else {
            text = shortcut.displayString
        }

        let color: NSColor = isRecording
            ? .controlAccentColor
            : (shortcut.isEmpty ? .tertiaryLabelColor : .labelColor)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    // MARK: 交互

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            stopRecording()
            return
        }
        // 窗口失焦时必须停录：否则用户切到别的 app，按键还被我们吞着
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
    }

    // MARK: 录制

    private func startRecording() {
        guard !isRecording else { return }
        pendingModifiers = 0

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        // 必须挂在 HID 层。fn 的「切换输入法 / Emoji / 听写」是系统在
        // session 之前处理的：挂 .cgSessionEventTap 能**看到** fn，却吞不掉
        // 系统那套行为——录 fn 时会弹出输入法切换面板。
        // .cghidEventTap 位于事件流最前端，在系统消费之前拦下。
        var tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,      // 要能吞事件，不能用 listenOnly
            eventsOfInterest: CGEventMask(mask),
            callback: shortcutRecorderTapCallback,
            userInfo: context
        )

        // HID 层不可用时退回 session 层：能录，但 fn 会连带触发系统行为，
        // 总比完全录不了强
        if tap == nil {
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: shortcutRecorderTapCallback,
                userInfo: context
            )
        }

        guard let tap else {
            // 没有辅助功能权限时创建失败。这时录不了任何键，
            // 但 app 的核心功能（合成按键）本来也需要该权限，会另有提示。
            NSSound.beep()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRecording = true

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.recordingTimeout,
                                            repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
    }

    private func stopRecording() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil

        pendingModifiers = 0
        isRecording = false
    }

    /// 与 handleTapEvent 一样，回调投递在主 runloop 上
    nonisolated fileprivate func reenableTap() {
        MainActor.assumeIsolated {
            guard let tap = eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// EventTap 的回调投递在主 runloop 上，所以这里确实在主线程
    nonisolated fileprivate func handleTapEvent(keyCode: UInt16, flags: CGEventFlags, isKeyDown: Bool) {
        MainActor.assumeIsolated {
            guard isRecording else { return }

            let mods = Shortcut.normalizeCG(flags)

            if isKeyDown {
                // Esc 取消录制（不带修饰键时）
                if keyCode == UInt16(kVK_Escape), mods == 0 {
                    stopRecording()
                    return
                }
                commit(Shortcut(keyCode: keyCode, modifiers: mods))
                return
            }

            // flagsChanged
            if mods != 0 {
                // 还按着，先记下。用户可能接着按主键，也可能就此松手。
                pendingModifiers = mods
                needsDisplay = true
            } else if pendingModifiers != 0 {
                // 修饰键全松开且始终没有主键 —— 认定为纯修饰键组合（如单独的 fn）
                commit(Shortcut(keyCode: nil, modifiers: pendingModifiers))
            }
        }
    }

    private func commit(_ new: Shortcut) {
        stopRecording()
        shortcut = new
        onChange?(new)
    }

    @objc private func clear() {
        commit(Shortcut(keyCode: nil, modifiers: 0))
    }

    func update(_ new: Shortcut) {
        shortcut = new
    }
}
