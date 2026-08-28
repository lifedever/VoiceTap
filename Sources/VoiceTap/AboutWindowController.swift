import Cocoa

/// 关于窗口：版本号、项目主页、捐赠。
/// 跟权限窗口分开——权限是「功能不可用时的排查入口」，关于是「了解这个 app」，
/// 混在一起会让权限窗口失去焦点。
@MainActor
final class AboutWindowController: NSWindowController {

    private static let width: CGFloat = 360

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AboutWindowController.width, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于 \(AppInfo.name)"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: AppInfo.name)
        nameLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let versionLabel = NSTextField(labelWithString: "版本 \(AppInfo.version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(wrappingLabelWithString: AppInfo.summary)
        descLabel.font = .systemFont(ofSize: 13, weight: .medium)
        descLabel.alignment = .center
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(wrappingLabelWithString: AppInfo.detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        // 没配置的链接不显示——放一个点开 404 的按钮比没有更糟
        var links: [NSView] = []
        if AppInfo.homepage != nil { links.append(linkButton("我的主页", action: #selector(openHomepage))) }
        if AppInfo.repository != nil { links.append(linkButton("开源仓库", action: #selector(openRepository))) }
        if AppInfo.donate != nil { links.append(linkButton("捐赠", action: #selector(openDonate))) }

        let linkStack = NSStackView(views: links)
        linkStack.orientation = .horizontal
        linkStack.spacing = 16
        linkStack.alignment = .centerY
        linkStack.translatesAutoresizingMaskIntoConstraints = false

        let copyright = NSTextField(labelWithString: AppInfo.copyright)
        copyright.font = .systemFont(ofSize: 10)
        copyright.textColor = .tertiaryLabelColor
        copyright.alignment = .center
        copyright.translatesAutoresizingMaskIntoConstraints = false

        for view in [iconView, nameLabel, versionLabel, descLabel, detailLabel, linkStack, copyright] as [NSView] {
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),

            iconView.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            nameLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            versionLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            descLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            detailLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            detailLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),

            linkStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 18),
            linkStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            copyright.topAnchor.constraint(equalTo: linkStack.bottomAnchor, constant: 18),
            copyright.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            content.bottomAnchor.constraint(equalTo: copyright.bottomAnchor, constant: 20),
        ])

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func openHomepage() { open(AppInfo.homepage) }
    @objc private func openRepository() { open(AppInfo.repository) }
    @objc private func openDonate() { open(AppInfo.donate) }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
