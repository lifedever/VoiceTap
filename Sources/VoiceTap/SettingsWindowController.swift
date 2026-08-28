import Cocoa

/// 设置窗口。
///
/// 触发键做成录制器而不是固定预设：VoiceTap 只负责「按下某个键」，
/// 谁监听那个键谁响应。所以只要和输入法里设的那个一致就能联动，
/// 用户想用什么组合是他自己的事，写死几个选项反而挡路。
@MainActor
final class SettingsWindowController: NSWindowController {

    var onTriggerChanged: (() -> Void)?
    var onBehaviorChanged: (() -> Void)?

    private var recorder: ShortcutRecorderView!
    private var thresholdSlider: NSSlider!
    private var thresholdLabel: NSTextField!

    private static let width: CGFloat = 460
    private static let padding: CGFloat = 24

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.width, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
    }

    func show() {
        recorder.update(Settings.shared.triggerShortcut)
        syncThreshold()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 界面

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        // —— 触发键 ——
        let triggerTitle = sectionTitle("触发键")
        let triggerDetail = detailLabel(
            "长按耳机线控时，VoiceTap 会按下这个快捷键。\n把它设成和输入法「按住说话」相同的快捷键即可联动。")

        recorder = ShortcutRecorderView(shortcut: Settings.shared.triggerShortcut)
        recorder.onChange = { [weak self] shortcut in
            Settings.shared.triggerShortcut = shortcut
            self?.onTriggerChanged?()
        }

        // —— 长按阈值 ——
        let thresholdTitle = sectionTitle("长按阈值")
        let thresholdDetail = detailLabel("按住超过这个时长才算长按；短于它算单击（播放/暂停）。")

        thresholdSlider = NSSlider(value: Settings.shared.longPressThreshold,
                                   minValue: 0.15, maxValue: 1.0,
                                   target: self, action: #selector(thresholdChanged))
        thresholdSlider.translatesAutoresizingMaskIntoConstraints = false

        thresholdLabel = NSTextField(labelWithString: "")
        thresholdLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        thresholdLabel.textColor = .secondaryLabelColor
        thresholdLabel.translatesAutoresizingMaskIntoConstraints = false

        // —— 行为开关 ——
        let behaviorTitle = sectionTitle("行为")

        let seizeCheck = checkbox("独占线控（长按说话时不暂停音乐）",
                                  on: Settings.shared.seizeDevice,
                                  action: #selector(toggleSeize))
        let clickCheck = checkbox("单击线控 = 播放/暂停",
                                  on: Settings.shared.singleClickPlayPause,
                                  action: #selector(toggleSingleClick))
        let micCheck = checkbox("插入耳机时自动切换到耳机麦克风",
                                on: Settings.shared.autoSwitchMicToHeadset,
                                action: #selector(toggleAutoMic))
        let updateCheck = checkbox("每天自动检查更新",
                                   on: Settings.shared.autoCheckUpdates,
                                   action: #selector(toggleAutoUpdate))

        let closeButton = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        let views: [NSView] = [triggerTitle, triggerDetail, recorder,
                               thresholdTitle, thresholdDetail, thresholdSlider, thresholdLabel,
                               behaviorTitle, seizeCheck, clickCheck, micCheck, updateCheck,
                               closeButton]
        for view in views { content.addSubview(view) }

        let pad = Self.padding
        let lead = { (v: NSView) in v.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad) }
        let trail = { (v: NSView) in v.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad) }

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),

            triggerTitle.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            lead(triggerTitle), trail(triggerTitle),

            triggerDetail.topAnchor.constraint(equalTo: triggerTitle.bottomAnchor, constant: 4),
            lead(triggerDetail), trail(triggerDetail),

            recorder.topAnchor.constraint(equalTo: triggerDetail.bottomAnchor, constant: 10),
            lead(recorder),

            thresholdTitle.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 22),
            lead(thresholdTitle), trail(thresholdTitle),

            thresholdDetail.topAnchor.constraint(equalTo: thresholdTitle.bottomAnchor, constant: 4),
            lead(thresholdDetail), trail(thresholdDetail),

            thresholdSlider.topAnchor.constraint(equalTo: thresholdDetail.bottomAnchor, constant: 10),
            lead(thresholdSlider),
            thresholdSlider.widthAnchor.constraint(equalToConstant: 260),

            thresholdLabel.leadingAnchor.constraint(equalTo: thresholdSlider.trailingAnchor, constant: 12),
            thresholdLabel.centerYAnchor.constraint(equalTo: thresholdSlider.centerYAnchor),

            behaviorTitle.topAnchor.constraint(equalTo: thresholdSlider.bottomAnchor, constant: 22),
            lead(behaviorTitle), trail(behaviorTitle),

            seizeCheck.topAnchor.constraint(equalTo: behaviorTitle.bottomAnchor, constant: 8),
            lead(seizeCheck),
            clickCheck.topAnchor.constraint(equalTo: seizeCheck.bottomAnchor, constant: 6),
            lead(clickCheck),
            micCheck.topAnchor.constraint(equalTo: clickCheck.bottomAnchor, constant: 6),
            lead(micCheck),
            updateCheck.topAnchor.constraint(equalTo: micCheck.bottomAnchor, constant: 6),
            lead(updateCheck),

            closeButton.topAnchor.constraint(equalTo: updateCheck.bottomAnchor, constant: 20),
            trail(closeButton),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            content.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: pad),
        ])

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        syncThreshold()
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        button.font = .systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func syncThreshold() {
        guard thresholdSlider != nil else { return }
        thresholdSlider.doubleValue = Settings.shared.longPressThreshold
        thresholdLabel.stringValue = String(format: "%.2f 秒", Settings.shared.longPressThreshold)
    }

    // MARK: 动作

    @objc private func thresholdChanged() {
        Settings.shared.longPressThreshold = thresholdSlider.doubleValue
        thresholdLabel.stringValue = String(format: "%.2f 秒", thresholdSlider.doubleValue)
    }

    @objc private func toggleSeize(_ sender: NSButton) {
        Settings.shared.seizeDevice = sender.state == .on
        onBehaviorChanged?()
    }

    @objc private func toggleSingleClick(_ sender: NSButton) {
        Settings.shared.singleClickPlayPause = sender.state == .on
    }

    @objc private func toggleAutoMic(_ sender: NSButton) {
        Settings.shared.autoSwitchMicToHeadset = sender.state == .on
        onBehaviorChanged?()
    }

    @objc private func toggleAutoUpdate(_ sender: NSButton) {
        Settings.shared.autoCheckUpdates = sender.state == .on
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
