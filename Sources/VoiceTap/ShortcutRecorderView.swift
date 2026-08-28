import Carbon.HIToolbox
import Cocoa

/// 快捷键录制控件。点一下开始录，按下想要的组合键即完成。
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
            widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            heightAnchor.constraint(equalToConstant: 26),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 绘制

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording ? "请按下快捷键…" : shortcut.displayString
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
        guard !isRecording else { return }
        isRecording = true
        pendingModifiers = 0
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    /// 录制期间必须抢在菜单和默认按钮之前拿到按键。
    ///
    /// key equivalent 的分发早于 responder chain：不拦的话，想把快捷键录成
    /// ⌘W 会直接关窗口、录成 ⌘Q 会退出 app、按回车会触发「完成」按钮，
    /// 这些组合永远录不进去。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Esc 取消录制，不写入
        if event.keyCode == UInt16(kVK_Escape), Shortcut.normalize(event.modifierFlags) == 0 {
            isRecording = false
            return
        }

        commit(Shortcut(keyCode: event.keyCode,
                        modifiers: Shortcut.normalize(event.modifierFlags)))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }

        let mods = Shortcut.normalize(event.modifierFlags)

        if mods != 0 {
            // 还按着，先记下来。用户可能接着按主键，也可能就此松手。
            pendingModifiers = mods
            needsDisplay = true
        } else if pendingModifiers != 0 {
            // 修饰键全松开且始终没有主键 —— 认定为纯修饰键组合（如单独的 fn）
            commit(Shortcut(keyCode: nil, modifiers: pendingModifiers))
        }
    }

    private func commit(_ new: Shortcut) {
        shortcut = new
        isRecording = false
        pendingModifiers = 0
        onChange?(new)
        window?.makeFirstResponder(nil)
    }

    @objc private func clear() {
        commit(Shortcut(keyCode: nil, modifiers: 0))
    }

    func update(_ new: Shortcut) {
        shortcut = new
    }
}
