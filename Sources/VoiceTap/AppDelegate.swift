import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = HeadsetMonitor()
    private let ptt = PTTController()
    private let diagnostics = DiagnosticsWindowController()
    private let audioWatcher = AudioDeviceWatcher()
    private lazy var permissionsWindow = PermissionsWindowController()
    private lazy var aboutWindow = AboutWindowController()
    private let updater = UpdateChecker()

    /// 权限状态轮询。用户是在系统设置里授权的，没有通知可订阅，
    /// 只能自己发现「刚被授权 / 刚被撤销」。
    private var permissionTimer: Timer?
    private var lastPermissionsGranted = false

    /// 被 HID 接管的设备。注意这**不**代表耳机插着——
    /// 插孔的 HID 节点是常驻的，是否真的插了耳机以 audioWatcher 为准。
    private var devices: [HeadsetDeviceInfo] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 所有全局入口都在这里注册。
        // 不挂在任何视图的生命周期上——后台启动时视图可能根本不会被创建，
        // 那样注册代码永不执行，功能会静默失效（PasteMemo issue #66）。
        setupStatusItem()

        ptt.onStateChange = { [weak self] _ in
            self?.updateIcon()
        }
        ptt.onLog = { [weak self] message in
            self?.diagnostics.append(message)
        }

        monitor.delegate = self

        // 上次若是崩溃退出的，修饰键可能还卡在按下状态，先清干净
        KeySynthesizer.clearModifiers()

        // 耳机插拔的唯一可靠信号源。HID 节点常驻，给不出这个信息。
        audioWatcher.onChange = { [weak self] plugged in
            self?.handleHeadsetPlugChange(plugged)
        }
        audioWatcher.start()

        buildMainMenu()
        observeSleep()
        observeWindowClose()
        checkPermissionsAndStart()

        updater.onLog = { [weak self] message in self?.diagnostics.append(message) }
        updater.startPeriodicChecks()
    }

    /// 状态栏程序默认没有主菜单，于是 ⌘W / ⌘Q 这些标准快捷键全都不响应。
    /// 建一个最小主菜单把它们挂上；平时 .accessory 不显示菜单栏，
    /// 打开窗口切到 .regular 时才出现。
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 \(AppInfo.name)",
                        action: #selector(openAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(AppInfo.name)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(AppInfo.name)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // 让事件监视器里的日志能选中复制
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func handleHeadsetPlugChange(_ plugged: Bool) {
        if plugged {
            diagnostics.append("耳机已插入")
            // 系统大多数时候会自己把输入切到耳机麦，但会记住上次选择、
            // 也可能被别的 app 抢走。开了这个开关就由我们兜底。
            // 稍等一下再切：插入瞬间系统自己也在调整，太早切会被覆盖。
            if Settings.shared.autoSwitchMicToHeadset {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.switchMicToHeadset(auto: true)
                }
            }
        } else {
            diagnostics.append("耳机已拔出")
            // 拔出瞬间可能正按着中键，那次「松开」永远不会到达
            ptt.forceRelease(reason: "耳机拔出")
        }
        updateIcon()
    }

    /// 耳机插着、但当前麦克风走的不是耳机麦 —— 说话会被电脑麦收音
    private var micMismatched: Bool {
        guard isHeadsetConnected else { return false }
        guard let current = AudioDeviceWatcher.currentInputDevice() else { return false }
        return !current.isHeadsetMic
    }

    @discardableResult
    private func switchMicToHeadset(auto: Bool) -> Bool {
        guard let headsetMic = AudioDeviceWatcher.headsetInputDevice() else { return false }
        guard AudioDeviceWatcher.currentInputDevice()?.uid != headsetMic.uid else { return true }

        let ok = AudioDeviceWatcher.setInputDevice(headsetMic)
        diagnostics.append(ok
            ? "\(auto ? "自动" : "手动")切换麦克风到「\(headsetMic.name)」"
            : "切换麦克风失败")
        updateIcon()
        return ok
    }

    /// 合盖睡眠时如果 PTT 正按着，醒来后触发键仍是按下状态。
    /// 睡眠前主动释放。
    private func observeSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ptt.forceRelease(reason: "系统睡眠")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前必须释放触发键，否则修饰键会永久卡在按下状态
        ptt.forceRelease(reason: "退出")
        monitor.stop()
        audioWatcher.stop()
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 图标状态，一眼看出当前状况，不占状态栏宽度：
    ///   缺权限   —— 橙色警告三角（最高优先级：此时整个功能是废的）
    ///   说话中   —— 红色波形
    ///   已接入   —— 耳机
    ///   未接入   —— 耳机带斜杠
    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        // 权限缺失优先于一切：没有权限时下面那些状态都没有意义。
        // 但仍保留耳机主体 —— 换成纯警告三角会丢掉「这是哪个 app」的识别性，
        // 菜单栏里一排图标时根本认不出是谁在报警。
        if !Permissions.allGranted {
            button.image = StatusIcon.make(base: "headphones", badge: .alert)
            button.contentTintColor = .systemOrange
            button.toolTip = "VoiceTap — \(statusText)，点击查看"
            return
        }

        if ptt.isPTTActive {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill",
                                   accessibilityDescription: "正在说话")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            button.toolTip = "VoiceTap — 正在说话"
            return
        }

        let symbol = isHeadsetConnected ? "headphones" : "headphones.slash"
        button.image = StatusIcon.make(base: symbol, badge: .sparkle)
        button.contentTintColor = nil
        button.toolTip = "VoiceTap — \(statusText)"
    }

    /// 以音频设备为准，不看 HID —— 插孔的 HID 节点常驻，用它判断会永远显示「已接入」
    private var isHeadsetConnected: Bool { audioWatcher.isPluggedIn }

    /// 不能只说「未接入」：停用和缺权限时同样没法工作，
    /// 混为一谈会让人一直去查耳机而不是去查权限。
    private var statusText: String {
        if let missing = missingPermissionNames { return "缺少\(missing)权限" }
        if !Settings.shared.enabled { return "已停用" }
        return isHeadsetConnected ? "耳机已接入" : "耳机未接入"
    }

    /// 菜单首行。未接入时把操作提示并进同一行，不另起一行说同一件事。
    private var menuStatusText: String {
        if let missing = missingPermissionNames { return "缺少\(missing)权限，功能无法使用" }
        if !Settings.shared.enabled { return "已停用" }
        return isHeadsetConnected ? "耳机已接入" : "耳机未接入，插上即可使用"
    }

    /// 缺哪几个权限。全齐返回 nil。
    private var missingPermissionNames: String? {
        var missing: [String] = []
        if Permissions.inputMonitoring != .granted { missing.append("输入监控") }
        if Permissions.accessibility != .granted { missing.append("辅助功能") }
        return missing.isEmpty ? nil : missing.joined(separator: "、")
    }

    // MARK: 启动监听

    private func checkPermissionsAndStart() {
        if Permissions.inputMonitoring != .granted {
            Permissions.requestInputMonitoring()
        }
        if Permissions.accessibility != .granted {
            Permissions.requestAccessibility()
        }

        lastPermissionsGranted = Permissions.allGranted

        // 缺权限 = 整个功能静默失效（按线控毫无反应、也不报错）。
        // 这种情况必须主动弹窗，不能只把状态藏在菜单里等用户自己发现。
        permissionsWindow.onPermissionsChanged = { [weak self] in
            self?.handlePermissionChange()
        }
        if !Permissions.allGranted {
            presentWindow { self.permissionsWindow.show() }
        }

        startPermissionPolling()

        if Settings.shared.enabled {
            monitor.start(seize: Settings.shared.seizeDevice)
        }
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handlePermissionChange() }
        }
    }

    private func handlePermissionChange() {
        let granted = Permissions.allGranted
        defer { updateIcon() }

        guard granted != lastPermissionsGranted else { return }
        lastPermissionsGranted = granted

        if granted {
            diagnostics.append("权限已齐备，重新启动监听")
            // Input Monitoring 是在 IOHIDManagerOpen 时校验的，
            // 刚授权时 manager 已经以失败状态打开过了，必须重开一次。
            restartMonitor()
        } else {
            diagnostics.append("权限被撤销，功能已失效")
            ptt.forceRelease(reason: "权限撤销")
            presentWindow { self.permissionsWindow.show() }
        }
    }

    private func restartMonitor() {
        ptt.forceRelease(reason: "重启监听")
        monitor.stop()
        if Settings.shared.enabled {
            monitor.start(seize: Settings.shared.seizeDevice)
        }
    }

    // MARK: 菜单动作

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        Settings.shared.enabled.toggle()
        restartMonitor()
    }

    @objc private func selectTriggerKey(_ sender: NSMenuItem) {
        guard let key = TriggerKey(rawValue: sender.representedObject as? String ?? "") else { return }
        ptt.forceRelease(reason: "切换触发键")
        Settings.shared.triggerKey = key

        if key.requiresIMEConfig {
            showIMEConfigHint(for: key)
        }
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.shared.longPressThreshold = value
    }

    @objc private func toggleSeize(_ sender: NSMenuItem) {
        Settings.shared.seizeDevice.toggle()
        restartMonitor()
    }

    @objc private func toggleSingleClick(_ sender: NSMenuItem) {
        Settings.shared.singleClickPlayPause.toggle()
    }

    @objc private func fixMicNow(_ sender: NSMenuItem) {
        switchMicToHeadset(auto: false)
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let device = AudioDeviceWatcher.inputDevices().first(where: { $0.uid == uid })
        else { return }
        if AudioDeviceWatcher.setInputDevice(device) {
            diagnostics.append("麦克风已切换到「\(device.name)」")
        } else {
            diagnostics.append("切换麦克风失败：\(device.name)")
        }
        updateIcon()
    }

    @objc private func toggleAutoSwitchMic(_ sender: NSMenuItem) {
        Settings.shared.autoSwitchMicToHeadset.toggle()
        // 刚打开就立刻应用一次，不用等下次插拔
        if Settings.shared.autoSwitchMicToHeadset, isHeadsetConnected {
            switchMicToHeadset(auto: true)
        }
    }

    @objc private func openDiagnostics(_ sender: NSMenuItem) {
        presentWindow { self.diagnostics.show() }
    }

    @objc private func openAbout(_ sender: NSMenuItem) {
        presentWindow { self.aboutWindow.show() }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updater.check(userInitiated: true)
    }

    @objc private func toggleAutoCheckUpdates(_ sender: NSMenuItem) {
        Settings.shared.autoCheckUpdates.toggle()
    }

    // MARK: Dock 图标
    //
    // 平时是纯状态栏程序（.accessory，不occupy Dock）；
    // 但一旦有窗口出现，就该按系统惯例在 Dock 里显示图标，
    // 否则窗口在 Cmd-Tab 里找不到、也无法从 Dock 切回来。

    private var managedWindows: [NSWindow] {
        [permissionsWindow.window, aboutWindow.window, diagnostics.window].compactMap { $0 }
    }

    private func presentWindow(_ present: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        present()
    }

    private func observeWindowClose() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let closing = note.object as? NSWindow
            Task { @MainActor in self?.restorePolicyIfNoWindows(excluding: closing) }
        }
    }

    private func restorePolicyIfNoWindows(excluding closing: NSWindow?) {
        // willClose 触发时窗口仍是 visible，必须把正在关的那个排除掉
        let stillOpen = managedWindows.contains { $0 !== closing && $0.isVisible }
        guard !stillOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func openPermissions(_ sender: NSMenuItem) {
        presentWindow { self.permissionsWindow.show() }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func showIMEConfigHint(for key: TriggerKey) {
        let alert = NSAlert()
        alert.messageText = "还需要在输入法里改一处设置"
        alert.informativeText = """
        你选择了「\(key.label)」作为触发键。

        请打开微信输入法设置 → 语音 → 把「按住说话」的快捷键改成同一个键，\
        否则按耳机线控时输入法收不到信号。

        （默认的 fn 选项不需要改输入法设置。）
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}

// MARK: - 菜单构建

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 每次打开都整体重建。不复用存储属性里的 NSMenuItem——
        // 同一个 item 没从旧菜单摘除就插进新菜单会抛 NSInternalInconsistencyException。
        menu.removeAllItems()

        // 每次打开菜单都反映当下真实状态
        menu.addItem(disabledItem(menuStatusText))

        if isHeadsetConnected {
            for device in devices {
                let mode = device.isSeized ? "独占" : "共享"
                menu.addItem(disabledItem("线控：\(device.product)（\(mode)）"))
            }

            // 耳机插着但麦没走耳机麦 = 说话被电脑麦收音，用户很难自己意识到
            if micMismatched {
                let fix = NSMenuItem(title: "麦克风未使用耳机麦，点此切换",
                                     action: #selector(fixMicNow(_:)), keyEquivalent: "")
                fix.target = self
                menu.addItem(fix)
            }
        }

        menu.addItem(.separator())

        // 麦克风输入源
        let micItem = NSMenuItem(title: "麦克风输入", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let current = AudioDeviceWatcher.currentInputDevice()
        for device in AudioDeviceWatcher.inputDevices() {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = (device.uid == current?.uid) ? .on : .off
            micMenu.addItem(item)
        }
        micMenu.addItem(.separator())
        let autoItem = NSMenuItem(title: "插入耳机时自动切换到耳机麦",
                                  action: #selector(toggleAutoSwitchMic(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = Settings.shared.autoSwitchMicToHeadset ? .on : .off
        micMenu.addItem(autoItem)

        micItem.submenu = micMenu
        micItem.title = "麦克风输入：\(current?.name ?? "未知")"
        menu.addItem(micItem)

        menu.addItem(.separator())

        // 主开关
        let enabledItem = NSMenuItem(title: "启用", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabledItem)

        // 触发键
        let triggerItem = NSMenuItem(title: "触发键", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for key in TriggerKey.allCases {
            let item = NSMenuItem(title: key.label, action: #selector(selectTriggerKey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = (Settings.shared.triggerKey == key) ? .on : .off
            triggerMenu.addItem(item)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        // 长按阈值
        let thresholdItem = NSMenuItem(title: "长按阈值", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for value in [0.2, 0.35, 0.5, 0.8] {
            let item = NSMenuItem(title: String(format: "%.2f 秒", value),
                                  action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(Settings.shared.longPressThreshold - value) < 0.01 ? .on : .off
            thresholdMenu.addItem(item)
        }
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        let seizeItem = NSMenuItem(title: "独占线控（长按不暂停音乐）",
                                   action: #selector(toggleSeize(_:)), keyEquivalent: "")
        seizeItem.target = self
        seizeItem.state = Settings.shared.seizeDevice ? .on : .off
        menu.addItem(seizeItem)

        let clickItem = NSMenuItem(title: "单击 = 播放/暂停",
                                   action: #selector(toggleSingleClick(_:)), keyEquivalent: "")
        clickItem.target = self
        clickItem.state = Settings.shared.singleClickPlayPause ? .on : .off
        clickItem.isEnabled = Settings.shared.seizeDevice
        menu.addItem(clickItem)

        menu.addItem(.separator())

        // 权限。统一一个入口，别让用户在菜单里逐项点。
        let permTitle = missingPermissionNames.map { "权限设置…（缺少\($0)）" } ?? "权限设置…（已全部授权）"
        let permItem = NSMenuItem(title: permTitle,
                                  action: #selector(openPermissions(_:)), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        menu.addItem(.separator())

        let diagItem = NSMenuItem(title: "事件监视器…", action: #selector(openDiagnostics(_:)), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)

        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let autoUpdateItem = NSMenuItem(title: "每天自动检查更新",
                                        action: #selector(toggleAutoCheckUpdates(_:)), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = Settings.shared.autoCheckUpdates ? .on : .off
        menu.addItem(autoUpdateItem)

        let aboutItem = NSMenuItem(title: "关于 \(AppInfo.name)…", action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出 VoiceTap", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - HeadsetMonitorDelegate

extension AppDelegate: HeadsetMonitorDelegate {

    func headsetButton(_ button: HeadsetButton, pressed: Bool, from product: String) {
        diagnostics.append("[\(product)] \(button.label) \(pressed ? "按下" : "松开")")
        guard Settings.shared.enabled else { return }
        ptt.handle(button: button, pressed: pressed)
    }

    func headsetDevicesChanged(_ devices: [HeadsetDeviceInfo]) {
        self.devices = devices
        updateIcon()
    }

    func headsetDeviceRemoved(_ product: String) {
        // 拔出瞬间可能正按着中键。那次「松开」永远不会来，
        // 不在这里释放，触发键就永久卡在按下状态。
        ptt.forceRelease(reason: "耳机拔出")
        updateIcon()
    }

    func headsetLog(_ message: String) {
        diagnostics.append(message)
    }
}
