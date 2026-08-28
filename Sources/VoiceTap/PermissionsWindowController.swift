import Cocoa

/// 权限窗口：只管权限。版本号、主页、捐赠属于「关于」，不混在这里。
///
/// 为什么值得单独做一个窗口：这两个权限缺任何一个，功能都是「静默不工作」——
/// 按线控没反应，但没有任何报错。用户唯一能自查的入口就是这里。
@MainActor
final class PermissionsWindowController: NSWindowController {

    /// 权限状态发生变化时回调（例如用户刚授权完），用于重启监听
    var onPermissionsChanged: (() -> Void)?

    private var rows: [PermissionRowView] = []
    private var refreshTimer: Timer?
    private var lastSnapshot: [Permissions.State] = []
    private var summaryLabel: NSTextField!

    private static let width: CGFloat = 480
    private static let padding: CGFloat = 24

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PermissionsWindowController.width, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "权限"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
    }

    // MARK: 展示

    /// 只在确实缺权限时才弹。全齐了就别打扰用户。
    func showIfNeeded() {
        guard !Permissions.allGranted else { return }
        show()
    }

    func show() {
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    // MARK: 界面

    private func buildContent() {
        guard let window else { return }

        let content = NSView()

        let headerIcon = NSImageView()
        headerIcon.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        headerIcon.contentTintColor = .controlAccentColor
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "VoiceTap 需要以下权限")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        rows = [
            PermissionRowView(
                icon: "keyboard",
                title: "输入监控",
                detail: "读取耳机线控的按键",
                onOpen: Permissions.openInputMonitoringSettings
            ),
            PermissionRowView(
                icon: "hand.tap",
                title: "辅助功能",
                detail: "把快捷键发送给输入法",
                onOpen: Permissions.openAccessibilitySettings
            ),
        ]

        let hint = NSTextField(wrappingLabelWithString: "授权后如果仍无反应，点「重启 VoiceTap」使权限生效。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let restartButton = NSButton(title: "重启 VoiceTap", target: self, action: #selector(restartApp))
        restartButton.bezelStyle = .rounded
        restartButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [headerIcon, title, summaryLabel, hint, restartButton, closeButton] as [NSView] {
            content.addSubview(view)
        }
        for row in rows { content.addSubview(row) }

        let pad = Self.padding
        var constraints: [NSLayoutConstraint] = [
            headerIcon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            headerIcon.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            headerIcon.widthAnchor.constraint(equalToConstant: 32),
            headerIcon.heightAnchor.constraint(equalToConstant: 32),

            title.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: headerIcon.topAnchor, constant: -2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -pad),

            summaryLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -pad),
        ]

        // 权限行依次往下排，每行高度固定 —— 之前用 NSBox 包 StackView 又不约束高度，
        // box 被拉伸导致行重叠、内容挤在底部。
        var previous: NSView = headerIcon
        var topSpacing: CGFloat = 20
        for row in rows {
            constraints += [
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
                row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: topSpacing),
                row.heightAnchor.constraint(equalToConstant: 62),
            ]
            previous = row
            topSpacing = 10
        }

        constraints += [
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            hint.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 16),

            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            closeButton.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            restartButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            restartButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            content.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: pad),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ]

        NSLayoutConstraint.activate(constraints)

        window.contentView = content
        // 先按约束算出内容尺寸，再定窗口大小；反过来会先以错误尺寸布局
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    // MARK: 刷新
    //
    // 用户是去**另一个 app**（系统设置）里授权的，回来时这边必须自己发现状态变了。
    // 没有通知可订阅，只能轮询；窗口关掉就停，不留后台定时器。

    private func startPolling() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        let states = [Permissions.inputMonitoring, Permissions.accessibility]
        for (row, state) in zip(rows, states) {
            row.update(state)
        }

        let missing = states.filter { $0 != .granted }.count
        summaryLabel.stringValue = missing == 0
            ? "已全部授权，功能正常"
            : "缺少 \(missing) 项权限。未授权时按线控没有任何反应，也不会报错。"
        summaryLabel.textColor = missing == 0 ? .secondaryLabelColor : .systemOrange

        if states != lastSnapshot {
            lastSnapshot = states
            onPermissionsChanged?()
        }
    }

    // MARK: 动作

    @objc private func closeWindow() {
        stopPolling()
        window?.close()
    }

    @objc private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

// MARK: - 单行

/// 一行权限。自绘圆角背景 + 左侧功能图标 + 右侧状态。
@MainActor
private final class PermissionRowView: NSView {

    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "打开设置", target: nil, action: nil)
    private let onOpen: () -> Void

    init(icon: String, title: String, detail: String, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(openSettings)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        for view in [iconView, titleLabel, detailLabel, statusIcon, statusLabel, actionButton] as [NSView] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusIcon.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -5),
            statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),

            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -10),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // 用 updateLayer 而不是在 init 里写死颜色 —— 深浅色切换时会自动重绘
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    func update(_ state: Permissions.State) {
        statusLabel.stringValue = state.label
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

        switch state {
        case .granted:
            statusLabel.textColor = .systemGreen
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                       accessibilityDescription: nil)?.withSymbolConfiguration(config)
            statusIcon.contentTintColor = .systemGreen
            actionButton.isHidden = true
        case .denied, .unknown:
            statusLabel.textColor = .systemOrange
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                       accessibilityDescription: nil)?.withSymbolConfiguration(config)
            statusIcon.contentTintColor = .systemOrange
            actionButton.isHidden = false
        }
    }

    @objc private func openSettings() {
        onOpen()
    }
}
