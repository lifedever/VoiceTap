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

                Text("关闭后不再响应任何触发，设置保留。")
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
                    Text("有新版本时提示，确认后自动安装。")
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

// MARK: - 语音输入法

private struct VoiceInputPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                if model.voiceInputMethods.isEmpty {
                    Label("没找到带语音输入的输入法", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    Picker("语音输入法", selection: Binding(
                        get: { model.voiceInputMethodID },
                        set: { model.voiceInputMethodID = $0 }
                    )) {
                        Text("不指定").tag("")
                        ForEach(model.voiceInputMethods) { ime in
                            Text(ime.name).tag(ime.id)
                        }
                    }

                    Text("说话时临时切到它，说完自动切回。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if model.selectedInputMethodMissing {
                    Label("原先选的输入法已不存在，请重新选择",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            // 两个快捷键必须放在一起看，否则分居两页时只看到两个一模一样的录制框，
            // 根本分不出谁是谁
            Section("快捷键") {
                Toggle(isOn: Binding(
                    get: { model.hotKeyEnabled },
                    set: { model.hotKeyEnabled = $0 }
                )) {
                    Text("用键盘快捷键触发")
                }
                .toggleStyle(.switch)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("你按的键")
                        Text("在任何 App 里按它说话，不用插耳机")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { model.hotKey },
                        set: { model.hotKey = $0 }
                    ))
                    .frame(width: 150, height: 26)
                }
                .disabled(!model.hotKeyEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发给输入法的键")
                        Text("需与输入法里设的语音快捷键一致")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { model.triggerShortcut },
                        set: { model.triggerShortcut = $0 }
                    ))
                    .frame(width: 150, height: 26)
                }

                // 这两条是真会出事的，留着
                if model.hotKeyEnabled, model.hotKey.isRiskyAsHotKey {
                    Label("单独用「\(model.hotKey.displayString)」会让它的组合键失效（如 ⌘C），建议改用 fn",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                if model.hotKeyEnabled, model.inputMonitoring != .granted {
                    Label("缺少「输入监控」权限，按下不会有反应",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
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

                // 两种模式都会撞上：轻点切换是每次开始/结束都撞，按住说话是
                // 单击（误触、或想暂停音乐）时撞。所以这里不再按模式区分。
                if !model.preemptNowPlaying {
                    Label("单击线控会被当成播放键唤起音乐 App，需在「耳机线控」里打开「禁止线控唤起音乐 App」",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                // 这个模式必须吞掉按键（单击就是功能本身），系统的单击行为救不回来
                if model.triggerMode == .toggle, model.hotKeyEnabled {
                    Label("这个模式会占用「\(model.hotKey.displayString)」的单击，"
                          + "系统的单点换输入法会失效；按住说话模式不受影响",
                          systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if model.triggerMode == .hold {
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
                    Text("线控按住超过这个时长算长按，短于算单击。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }
}

// MARK: - 耳机线控

private struct HeadsetPane: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Text(model.triggerMode == .hold
                     ? "按住线控中键说话，松开出字。"
                     : "轻点线控中键开始，再轻点结束。点状态栏图标也能结束，2 分钟自动兜底。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                .disabled(!model.seizeDevice
                          || model.triggerMode.keepsRecordingAfterRelease
                          || model.preemptNowPlaying)

                if model.triggerMode.keepsRecordingAfterRelease {
                    Text("切换模式下中键已被占用，播放控制补不回来。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if model.preemptNowPlaying {
                    // 不说的话表现是「开关明明开着，按线控却不播放」，
                    // 而这两项隔着一个 Section，用户很难自己连上因果
                    Text("「禁止线控唤起音乐 App」开着时，补回去的这一发会被一并挡下。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text("按键不再传给系统，播放和音量由 VoiceTap 补回。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.preemptNowPlaying },
                    set: { model.preemptNowPlaying = $0 }
                )) {
                    Text("禁止线控唤起音乐 App")
                }
                .toggleStyle(.switch)

                // 和状态栏菜单里那一项是同一个开关，名字必须一字不差，
                // 否则会被当成两个互不相干的设置
                Text("单击线控会被系统当成播放键，把「音乐」拉起来抢走焦点，独占线控也拦不住。"
                     + "打开后由 VoiceTap 接住这条命令。"
                     + "代价：耳机接入期间线控和键盘的播放键都会失效。")
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
        case general, voiceInput, headset, microphone, permissions, about
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
        let voiceInput = NSHostingController(rootView: VoiceInputPane(model: model))
        let headset = NSHostingController(rootView: HeadsetPane(model: model))
        let microphone = NSHostingController(rootView: MicrophonePane(model: model))
        let permissions = NSHostingController(rootView: PermissionsPane(model: model))
        let about = NSHostingController(rootView: AboutPane())

        let controllers: [NSViewController] = [general, voiceInput, headset, microphone, permissions, about]
        // 让 preferredContentSize 跟随 SwiftUI 内容：NSTabViewController
        // 切 tab 时按它做窗口尺寸动画
        general.sizingOptions = [.preferredContentSize]
        voiceInput.sizingOptions = [.preferredContentSize]
        headset.sizingOptions = [.preferredContentSize]
        microphone.sizingOptions = [.preferredContentSize]
        permissions.sizingOptions = [.preferredContentSize]
        about.sizingOptions = [.preferredContentSize]

        let titles = ["通用", "语音输入", "耳机线控", "麦克风", "权限", "关于"]
        let symbols = ["gearshape", "waveform", "headphones", "mic", "lock.shield", "info.circle"]

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
