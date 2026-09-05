import AppKit
import SwiftUI

private let paneWidth: CGFloat = 460

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.enabled },
                    set: { model.enabled = $0 }
                )) {
                    Text("启用 VoiceTap")
                }
                .toggleStyle(.switch)

                Text("关闭后不再响应耳机线控，其余设置保留。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.launchState.isOn },
                    set: { model.setLaunchAtLogin($0) }
                )) {
                    Text("开机时启动")
                }
                .toggleStyle(.switch)

                if model.launchState == .requiresApproval {
                    Label("需要在「系统设置 → 通用 → 登录项」中批准",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.autoCheckUpdates },
                    set: { model.autoCheckUpdates = $0 }
                )) {
                    Text("每天自动检查更新")
                }
                .toggleStyle(.switch)

                HStack {
                    Text("有新版本时提示你，确认后自动装好重启。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即检查") { model.onCheckUpdates?() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }
}

// MARK: - 触发键

private struct TriggerPane: View {
    @ObservedObject var model: SettingsViewModel

    private var triggerModeHint: String {
        switch model.triggerMode {
        case .hold:
            "按住线控中键说话，松开出字。手离开按钮就一定会结束。"
        case .toggle:
            "轻点一下开始说话，手可以离开耳机，再轻点一下才结束。"
            + "说话时状态栏图标变成波形，点它可以立刻结束；"
            + "点鼠标或切到别的 App 也会自动结束，忘了关的话 2 分钟后兜底。"
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("触发键")
                        Text("说话期间按住的快捷键")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { model.triggerShortcut },
                        set: { model.triggerShortcut = $0 }
                    ))
                    .frame(width: 160, height: 26)
                }

                Text("把它设成和输入法「按住说话」相同的快捷键即可联动。"
                     + "VoiceTap 只负责按下这个键，谁监听它谁响应，因此不限于某一款输入法。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("触发方式", selection: Binding(
                    get: { model.triggerMode },
                    set: { model.triggerMode = $0 }
                )) {
                    ForEach(TriggerMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(triggerModeHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if model.triggerMode == .toggle, !model.preemptNowPlaying {
                    Label("轻点会被系统当成播放键，唤起音乐 App 并抢走输入焦点。"
                          + "打开下面的「抢占正在播放」才能挡住。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            if model.triggerMode == .hold {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("按住阈值")
                            Spacer()
                            Text(String(format: "%.2f 秒", model.longPressThreshold))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { model.longPressThreshold },
                            set: { model.longPressThreshold = $0 }
                        ), in: 0.15...1.0)
                    }

                    Text("按住超过这个时长才算长按；短于它算单击。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if model.triggerMode == .toggle {
                Section {
                    Toggle(isOn: Binding(
                        get: { model.preemptNowPlaying },
                        set: { model.preemptNowPlaying = $0 }
                    )) {
                        Text("抢占系统的「正在播放」")
                    }
                    .toggleStyle(.switch)

                    Text("把 VoiceTap 注册成当前播放器，线控的播放命令就会落到它手里，"
                         + "系统不再启动音乐 App。这是轻点切换唯一能挡住它的办法，"
                         + "别关。只在有线耳机接入期间生效，拔掉就交还。"
                         + "代价：接入期间控制中心会显示 VoiceTap 在播放，"
                         + "键盘上的播放键也会失效——命令同样只发到 VoiceTap。"
                         + "介意的话改用「按住说话」，那个模式不需要这个开关。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.seizeDevice },
                    set: { model.seizeDevice = $0 }
                )) {
                    Text("独占线控")
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(
                    get: { model.singleClickPlayPause },
                    set: { model.singleClickPlayPause = $0 }
                )) {
                    Text("单击线控 = 播放/暂停")
                }
                .toggleStyle(.switch)
                .disabled(!model.seizeDevice || model.triggerMode.keepsRecordingAfterRelease)

                if model.triggerMode.keepsRecordingAfterRelease {
                    Text("切换模式下中键用来开始/结束说话，播放控制补不回来；音量键不受影响。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text("独占后按键不再传给系统，长按说话时不会误暂停音乐；"
                     + "播放和音量控制由 VoiceTap 合成补回。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }
}

// MARK: - 麦克风

private struct MicrophonePane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Picker("输入设备", selection: Binding(
                    get: { model.currentInputUID },
                    set: { model.selectInputDevice(uid: $0) }
                )) {
                    ForEach(model.inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                if model.micMismatched {
                    HStack {
                        Label("耳机已接入，但录音走的不是耳机麦",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("切换") { model.switchToHeadsetMic() }
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.autoSwitchMic },
                    set: { model.autoSwitchMic = $0 }
                )) {
                    Text("插入耳机时自动切换到耳机麦克风")
                }
                .toggleStyle(.switch)

                Text("macOS 多数时候会自己切，但它会记住上次选择，"
                     + "也可能被别的 app 抢走。打开后由 VoiceTap 兜底。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }
}

// MARK: - 权限

private struct PermissionsPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    icon: "keyboard",
                    title: "输入监控",
                    detail: "读取耳机线控的按键",
                    state: model.inputMonitoring,
                    open: Permissions.openInputMonitoringSettings
                )
                PermissionRow(
                    icon: "hand.tap",
                    title: "辅助功能",
                    detail: "把快捷键发送给输入法",
                    state: model.accessibility,
                    open: Permissions.openAccessibilitySettings
                )
            } footer: {
                Text(model.allPermissionsGranted
                     ? "已全部授权，功能正常。"
                     : "缺少权限时按线控不会有任何反应，也不会报错。")
                    .font(.system(size: 11))
                    .foregroundStyle(model.allPermissionsGranted
                                     ? AnyShapeStyle(.secondary)
                                     : AnyShapeStyle(Color.orange))
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("授权后仍无反应？")
                        Text("输入监控在启动时校验，需要重启才能生效")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重启 VoiceTap") { restartApp() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }

    private func restartApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let state: Permissions.State
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state == .granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Label("未授权", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                Button("打开设置", action: open)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 关于

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 0) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.top, 28)
            }

            Text(AppInfo.name)
                .font(.system(size: 20, weight: .semibold))
                .padding(.top, 12)

            Text("版本 \(AppInfo.version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(AppInfo.summary)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(AppInfo.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            HStack(spacing: 16) {
                if let url = AppInfo.homepage { link("我的主页", url) }
                if let url = AppInfo.repository { link("开源仓库", url) }
                if let url = AppInfo.donate { link("捐赠", url) }
            }
            .padding(.top, 18)

            Text(AppInfo.copyright)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(width: paneWidth)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button(title) { NSWorkspace.shared.open(url) }
            .buttonStyle(.link)
            .font(.system(size: 12))
    }
}

// MARK: - 快捷键录制器的 SwiftUI 包装

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(shortcut: shortcut)
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        guard view.shortcut != shortcut else { return }
        view.update(shortcut)
    }
}

// MARK: - 窗口

// macOS 26 的「玻璃」外观长在窗口的 titlebar/toolbar 上：SwiftUI `TabView`
// 渲染出来的是内容区里的一颗分段控件，永远得不到那层玻璃。要拿到系统设置
// 那种效果，tab 必须真的住进 toolbar —— 这正是 NSTabViewController 的
// `.toolbar` 样式，切换时的窗口尺寸动画、顶边锚定也都是它的原生行为。
//
// 窗口标题必须设在 NSTabViewController 上而不是 window 上：
// NSWindow(contentViewController:) 会把 window.title **绑定**到
// contentViewController.title，直接写 window.title 会被绑定覆盖回 "Untitled"。

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    enum Pane: Int {
        case general, trigger, microphone, permissions, about
    }

    let model: SettingsViewModel

    private var window: NSWindow?
    private var tabController: NSTabViewController?

    init(model: SettingsViewModel) {
        self.model = model
        super.init()
    }

    var windowRef: NSWindow? { window }

    func show(pane: Pane = .general) {
        // 用户可能刚在系统设置里改过权限或登录项，每次打开都对一次账
        model.refreshSystemState()

        if window == nil { build() }

        tabController?.selectedTabViewItemIndex = pane.rawValue
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let general = NSHostingController(rootView: GeneralPane(model: model))
        let trigger = NSHostingController(rootView: TriggerPane(model: model))
        let microphone = NSHostingController(rootView: MicrophonePane(model: model))
        let permissions = NSHostingController(rootView: PermissionsPane(model: model))
        let about = NSHostingController(rootView: AboutPane())

        let controllers: [NSViewController] = [general, trigger, microphone, permissions, about]
        // 让 preferredContentSize 跟随 SwiftUI 内容：NSTabViewController
        // 切 tab 时按它做窗口尺寸动画
        general.sizingOptions = [.preferredContentSize]
        trigger.sizingOptions = [.preferredContentSize]
        microphone.sizingOptions = [.preferredContentSize]
        permissions.sizingOptions = [.preferredContentSize]
        about.sizingOptions = [.preferredContentSize]

        let titles = ["通用", "触发键", "麦克风", "权限", "关于"]
        let symbols = ["gearshape", "command", "mic", "lock.shield", "info.circle"]

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for (index, controller) in controllers.enumerated() {
            let item = NSTabViewItem(viewController: controller)
            item.label = titles[index]
            item.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        tabs.title = "设置"
        tabController = tabs

        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self

        // 必须先把内容布局出来再居中：自适应尺寸的窗口如果在内容到位前
        // center()，会以近零尺寸算中心，随后内容以左上角为锚向右下展开，
        // 窗口最终落在屏幕右下象限。
        tabs.view.layoutSubtreeIfNeeded()
        w.setContentSize(general.view.fittingSize)
        w.center()
        window = w
    }
}
