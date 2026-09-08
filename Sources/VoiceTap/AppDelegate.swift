import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    /// 说话期间会被临时从 statusItem 上摘下来，见 `updateStatusItemClickBehavior`
    private var statusMenu: NSMenu!
    private let monitor = HeadsetMonitor()
    private let ptt = PTTController()
    private let diagnostics = DiagnosticsWindowController()
    private let nowPlayingGuard = NowPlayingGuard()
    private let hotKey = GlobalHotKey()
    private let audioWatcher = AudioDeviceWatcher()
    private let settingsModel = SettingsViewModel()
    private lazy var settingsWindow = SettingsWindowController(model: settingsModel)
    private let updater = UpdateChecker()

    /// 外部状态轮询。权限是用户在系统设置里改的，没有通知可订阅，
    /// 只能自己发现「刚被授权 / 刚被撤销」；耳机在场也在这里兜底对账。
    private var stateTimer: Timer?
    private var lastPermissionsGranted = false

    /// 被 HID 接管的设备。注意这**不**直接代表耳机插着——
    /// 3.5mm 插孔的 HID 节点是常驻的，只有 `isRemovable` 的那些才算证据。
    private var devices: [HeadsetDeviceInfo] = []

    /// 「耳机在场」的唯一事实源，由 `refreshHeadsetPresence()` 维护。
    private var headsetPresent = false

    /// 说话期间的自动停止监听，只在说话期间存在
    private var autoStopMonitors: [Any] = []
    private var autoStopActivation: NSObjectProtocol?
    private var autoStopArmedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 所有全局入口都在这里注册。
        // 不挂在任何视图的生命周期上——后台启动时视图可能根本不会被创建，
        // 那样注册代码永不执行，功能会静默失效（PasteMemo issue #66）。
        setupStatusItem()

        ptt.onStateChange = { [weak self] speaking in
            guard let self else { return }
            self.updateIcon()
            self.updateStatusItemClickBehavior(speaking: speaking)
            // 只有切换模式需要自动收尾。按住说话本来就有「松手」这条出口，
            // 给它加自动停止只会在用户还按着按钮时把话截断。
            if speaking, Settings.shared.triggerMode.keepsRecordingAfterRelease {
                self.startAutoStopWatch()
            } else {
                self.stopAutoStopWatch()
            }
        }
        ptt.onLog = { [weak self] message in
            self?.diagnostics.append(message)
        }

        monitor.delegate = self

        nowPlayingGuard.onLog = { [weak self] message in self?.diagnostics.append(message) }

        hotKey.onLog = { [weak self] message in self?.diagnostics.append(message) }
        hotKey.onHotKey = { [weak self] pressed in
            // 开关关掉时不响应。tap 撤除有延迟，中间那一拍可能还会进来
            guard Settings.shared.enabled else { return }
            self?.ptt.handleHotKey(pressed: pressed)
        }
        ptt.inputMethodSwitcher.onLog = { [weak self] message in self?.diagnostics.append(message) }

        // 上次若是崩溃退出的，修饰键可能还卡在按下状态，先清干净
        KeySynthesizer.clearModifiers()

        audioWatcher.onChange = { [weak self] _ in
            self?.refreshHeadsetPresence()
        }
        audioWatcher.start()

        // 启动时把聚合状态对齐到真实值，不当成「刚插入」处理——
        // 否则每次启动都会刷一条「耳机已插入」并触发一次自动切麦。
        // 图标是在这之前画的（那时状态还是初始值），这里补一次，
        // 不然耳机插着也要等轮询过一轮才纠正。
        headsetPresent = audioWatcher.isPluggedIn
        updateIcon()

        buildMainMenu()
        observeSleep()
        observeWindowClose()
        checkPermissionsAndStart()

        updater.onLog = { [weak self] message in self?.diagnostics.append(message) }
        updater.startPeriodicChecks()

        // 换触发键/触发方式时先把当前按着的那个释放掉，顺序不能反：
        // 用新键去 release 等于旧键永远卡在按下状态
        settingsModel.onTriggerChanged = { [weak self] reason in
            self?.ptt.forceRelease(reason: reason)
            self?.refreshNowPlayingGuard()
        }
        settingsModel.onMonitorSettingChanged = { [weak self] in
            self?.restartMonitor()
        }
        settingsModel.onNowPlayingSettingChanged = { [weak self] in
            self?.refreshNowPlayingGuard()
        }
        settingsModel.onHotKeySettingChanged = { [weak self] in
            self?.refreshHotKey()
        }
        settingsModel.onAutoMicEnabled = { [weak self] in
            guard self?.isHeadsetConnected == true else { return }
            self?.switchMicToHeadset(auto: true)
        }
        settingsModel.onCheckUpdates = { [weak self] in
            self?.updater.check(userInitiated: true)
        }

        // 用户可能在系统设置里改了权限或登录项再切回来，重新对一次账
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsModel.refreshSystemState() }
        }
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

    /// 重算「耳机在不在」。两路信号源互补，都不能单独作数：
    ///
    /// - **Core Audio**（`audioWatcher`）：3.5mm 唯一可靠的插拔信号（HID 节点常驻），
    ///   同时也覆盖 USB 耳机（整个音频设备随插拔增删）。
    /// - **HID**：兜住「有线控、但认不出对应音频设备」的边缘设备
    ///   （只算 `isRemovable` 的——3.5mm 那个常驻节点在这里永远不作数）。
    ///
    /// 收敛成一个状态再比对，同一次插拔两路都报也只会处理一次。
    private func refreshHeadsetPresence() {
        let present = audioWatcher.isPluggedIn || devices.contains(where: \.isRemovable)
        guard present != headsetPresent else {
            updateIcon()
            return
        }
        headsetPresent = present
        handleHeadsetPlugChange(present)
    }

    private func handleHeadsetPlugChange(_ plugged: Bool) {
        if plugged {
            let mic = AudioDeviceWatcher.headsetInputDevice()
            diagnostics.append("耳机已插入\(mic.map { "：\($0.name)" } ?? "")")
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
        // 「正在播放」位置跟着耳机走：插上才抢，拔了就还。
        // 挂在这个聚合后的事件上而不是 HID 那条路上——位置晚一拍还回去无害，
        // 不像触发键那样要抢时间。
        refreshNowPlayingGuard()
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
        hotKey.stop()
        monitor.stop()
        nowPlayingGuard.stop()
        audioWatcher.stop()
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        statusItem.menu = menu
    }

    /// 说话中点一下图标 = 立刻结束这次输入。
    ///
    /// NSStatusItem 一旦设了 `menu` 就吃掉点击、只弹菜单，和 action 互斥——
    /// 所以说话期间把菜单摘下来换成 action，结束后装回去。右键仍然弹菜单：
    /// 不能为了一个快捷出口把设置入口整个堵死。
    ///
    /// 摘下来就必须装得回去，否则菜单永久消失。唯一的装回路径是
    /// `onStateChange(false)`，而所有 `endPTT` 出口都会走到它。
    private func updateStatusItemClickBehavior(speaking: Bool) {
        guard let button = statusItem?.button else { return }
        if speaking {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        } else {
            button.target = nil
            button.action = nil
            statusItem.menu = statusMenu
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // 临时把菜单装回去弹一次。performClick 会一直阻塞到菜单关闭，
            // 弹完要摘掉——留着的话下一次左键点击又变成弹菜单，
            // 「点图标结束输入」就没了。
            //
            // 但只有「还在说话」才摘：菜单开着的这段时间里输入可能已经结束了
            // （超时保护、耳机拔出、切了别的 App），那时 menu 是刚被装回去的正常状态，
            // 再摘一次就永久摘掉了 —— 状态栏图标从此点不出菜单。
            statusItem.menu = statusMenu
            sender.performClick(nil)
            if ptt.isPTTActive { statusItem.menu = nil }
            return
        }
        ptt.forceRelease(reason: "点击状态栏图标")
    }

    // MARK: 说话中的自动停止
    //
    // 切换模式下触发键会一直按着，而它多半是 fn 这类修饰键：用户一旦去干别的
    // （点鼠标、切到别的窗口），后续输入全都会带上这个修饰键，键盘行为整个错乱。
    // 所以说话期间盯住这两件事，一发生就收尾。
    //
    // 监听只在说话期间存在。常驻一个全局事件监听既没必要，也多一份「忘了拆」的风险。

    /// 刚开始说话的这一小段不算数：合成触发键会引起输入法弹面板之类的连锁反应，
    /// 其中任何一步若碰巧激活了别的进程，语音输入会刚开就被自己停掉。
    private static let autoStopGrace: TimeInterval = 0.6

    private func startAutoStopWatch() {
        stopAutoStopWatch()
        autoStopArmedAt = Date()

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor in self?.autoStop(reason: "鼠标操作") }
        }) {
            autoStopMonitors.append(global)
        }
        // 本 app 内的点击（状态栏图标、设置窗口）到不了 global monitor
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            Task { @MainActor in self?.autoStop(reason: "鼠标操作") }
            return event
        }) {
            autoStopMonitors.append(local)
        }

        autoStopActivation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.autoStop(reason: "切换到其他 App") }
        }
    }

    private func stopAutoStopWatch() {
        for monitor in autoStopMonitors { NSEvent.removeMonitor(monitor) }
        autoStopMonitors.removeAll()
        if let observer = autoStopActivation {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            autoStopActivation = nil
        }
        autoStopArmedAt = nil
    }

    private func autoStop(reason: String) {
        guard ptt.isPTTActive else { return }
        if let armed = autoStopArmedAt, Date().timeIntervalSince(armed) < Self.autoStopGrace { return }
        ptt.forceRelease(reason: reason)
    }

    /// 图标状态，一眼看出当前状况，不占状态栏宽度：
    ///   缺权限   —— 耳机 + 角上感叹号（最高优先级：此时整个功能是废的）
    ///   说话中   —— 波形
    ///   已接入   —— 耳机 + sparkle
    ///   未接入   —— 耳机带斜杠
    ///
    /// 全部 template，跟菜单栏前景色走，和旁边其他 app 的图标一致。
    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        // 权限缺失优先于一切：没有权限时下面那些状态都没有意义。
        // 但仍保留耳机主体 —— 换成纯警告三角会丢掉「这是哪个 app」的识别性，
        // 菜单栏里一排图标时根本认不出是谁在报警。
        if !Permissions.allGranted {
            // 不染色：菜单栏图标就该跟其他图标一样跟随系统前景色（深色菜单栏下是白的），
            // 单独染一个颜色出来反而显得是坏了。异常状态靠角上的感叹号区分就够。
            button.image = StatusIcon.make(base: "headphones", badge: .alert)
            button.contentTintColor = nil
            button.toolTip = "VoiceTap — \(statusText)，点击查看"
            return
        }

        if ptt.isPTTActive {
            button.image = StatusIcon.make(base: "waveform", badge: .none)
            button.contentTintColor = nil
            button.toolTip = "VoiceTap — 正在说话，点击结束"
            return
        }

        // 没耳机但键盘快捷键还能用时，headphones.slash 是误导——那表示「用不了」
        let symbol: String
        if isHeadsetConnected { symbol = "headphones" }
        else if hotKeyUsable { symbol = "keyboard" }
        else { symbol = "headphones.slash" }
        button.image = StatusIcon.make(base: symbol, badge: .sparkle)
        button.contentTintColor = nil
        button.toolTip = "VoiceTap — \(statusText)"
    }

    private var isHeadsetConnected: Bool { headsetPresent }

    /// 不能只说「未接入」：停用和缺权限时同样没法工作，
    /// 混为一谈会让人一直去查耳机而不是去查权限。
    /// 键盘快捷键这条路通不通。它和耳机无关——没插耳机照样能按。
    private var hotKeyUsable: Bool {
        Settings.shared.enabled
            && Settings.shared.hotKeyEnabled
            && Permissions.inputMonitoring == .granted
    }

    private var statusText: String {
        if let missing = missingPermissionNames { return "缺少\(missing)权限" }
        if !Settings.shared.enabled { return "已停用" }
        if isHeadsetConnected { return "耳机已接入" }
        // 有键盘快捷键就不是「不可用」状态，别再报耳机
        return hotKeyUsable ? "按 \(Settings.shared.hotKey.displayString) 说话" : "耳机未接入"
    }

    /// 菜单首行。未接入时把操作提示并进同一行，不另起一行说同一件事。
    private var menuStatusText: String {
        if let missing = missingPermissionNames { return "缺少\(missing)权限，功能无法使用" }
        if !Settings.shared.enabled { return "已停用" }
        if isHeadsetConnected { return "耳机已接入" }
        return hotKeyUsable
            ? "按 \(Settings.shared.hotKey.displayString) 说话（耳机未接入）"
            : "耳机未接入，插上即可使用"
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
        if !Permissions.allGranted {
            presentWindow { self.settingsWindow.show(pane: .permissions) }
        }

        startStatePolling()

        if Settings.shared.enabled {
            monitor.start(seize: Settings.shared.seizeDevice)
        }
        refreshNowPlayingGuard()
        refreshHotKey()
    }

    /// 轮询那些没有可靠通知的外部状态：权限（系统不发通知）、
    /// 耳机在场（Core Audio 的 listener 会在设备刚出现、声道配置还没就绪时误判一拍）。
    private func startStatePolling() {
        stateTimer?.invalidate()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handlePermissionChange()
                self?.audioWatcher.recheck()
            }
        }
    }

    private func handlePermissionChange() {
        let granted = Permissions.allGranted
        defer { updateIcon() }

        // 设置窗口开着时，权限那一栏要跟着系统里的改动实时更新
        if settingsWindow.windowRef?.isVisible == true {
            settingsModel.refreshSystemState()
        }

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
            refreshNowPlayingGuard()
            refreshHotKey()
            presentWindow { self.settingsWindow.show(pane: .permissions) }
        }
    }

    private func restartMonitor() {
        ptt.forceRelease(reason: "重启监听")
        monitor.stop()
        if Settings.shared.enabled {
            monitor.start(seize: Settings.shared.seizeDevice)
        }
        refreshNowPlayingGuard()
        refreshHotKey()
    }

    /// 全局快捷键的启停条件。
    ///
    /// 和 `refreshNowPlayingGuard` 同构：条件由几个独立的开关和外部状态共同决定，
    /// 任何一个变了都要重新过一遍这里，否则状态会停在上一次的结论上。
    ///
    /// 权限只看「输入监控」——那是 `CGEvent.tapCreate` 的硬门槛，没有它监听
    /// 根本建不起来。合成触发键还要「辅助功能」，但那条缺了至少日志里能看到
    /// 按键收到了，比整个监听都起不来更好排查。
    private func refreshHotKey() {
        let wanted = Settings.shared.enabled
            && Settings.shared.hotKeyEnabled
            && Permissions.inputMonitoring == .granted
        if wanted {
            // 只有轻点切换需要吞事件的能力；按住说话用 listenOnly，
            // 否则 .defaultTap 会连带废掉 fn 的系统单击行为
            hotKey.start(shortcut: Settings.shared.hotKey,
                         swallows: Settings.shared.triggerMode == .toggle)
        } else {
            hotKey.stop()
        }
    }

    /// 抢占「正在播放」只在轻点切换下才有意义：按住说话不会让 `rcd` 发出
    /// 播放命令（它只把短按当播放键），开着纯属白占控制中心的位置。
    ///
    /// 同理，线控短按只有在**有线耳机在场且权限齐备**时才可能到来、才值得截：
    /// 没耳机就没有那一下；没「输入监控」就收不到 HID 事件，时间窗永远不满足，
    /// 每条命令都返回失败，位置却一直占着。任一条不成立都要把位置交还——
    /// 占着的代价（控制中心被占、键盘播放键失效）是实打实的。
    ///
    /// 所以除了三个开关，每次耳机插拔（`handleHeadsetPlugChange`）和
    /// 权限变化（`handlePermissionChange`）都要重新过一遍这里。
    private func refreshNowPlayingGuard() {
        let wanted = Settings.shared.enabled
            && Settings.shared.preemptNowPlaying
            && Settings.shared.triggerMode == .toggle
            && headsetPresent
            && Permissions.allGranted
        if wanted {
            nowPlayingGuard.start()
        } else {
            nowPlayingGuard.stop()
        }
    }

    // MARK: 菜单动作

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        // 走 model 而不是直接改 Settings：设置窗口开着时那个开关要跟着动，
        // 两处各改各的迟早出现「菜单说开着、设置里显示关着」
        settingsModel.enabled.toggle()
    }

    @objc private func selectVoiceInputMethod(_ sender: NSMenuItem) {
        // 走 ViewModel 而不是直接写 Settings：它的 didSet 会先把可能正借着的
        // 输入法还回去，再写新值。顺序反了，用户原来的输入法就再也回不来。
        settingsModel.voiceInputMethodID = sender.representedObject as? String ?? ""
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TriggerMode(rawValue: raw)
        else { return }
        // 走 model 而不是直接改 Settings：设置窗口开着时那个单选要跟着动，
        // 而且它的 didSet 会先把正按着的触发键释放掉
        settingsModel.triggerMode = mode
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        presentWindow { self.settingsWindow.show() }
    }

    @objc private func openPermissionsPane(_ sender: NSMenuItem) {
        presentWindow { self.settingsWindow.show(pane: .permissions) }
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

    @objc private func openDiagnostics(_ sender: NSMenuItem) {
        presentWindow { self.diagnostics.show() }
    }

    @objc private func openAbout(_ sender: NSMenuItem) {
        presentWindow { self.settingsWindow.show(pane: .about) }
    }


    // MARK: Dock 图标
    //
    // 平时是纯状态栏程序（.accessory，不occupy Dock）；
    // 但一旦有窗口出现，就该按系统惯例在 Dock 里显示图标，
    // 否则窗口在 Cmd-Tab 里找不到、也无法从 Dock 切回来。

    private var managedWindows: [NSWindow] {
        [settingsWindow.windowRef, diagnostics.window].compactMap { $0 }
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

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
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
            // 3.5mm 那个 HID 节点是常驻的，插孔空着时它仍在列表里。
            // 直接列出去会让人以为线控抓到了，得先确认插孔真的占着。
            let jackOccupied = AudioDeviceWatcher.builtInJackOccupied()
            let controls = devices.filter { $0.isRemovable || jackOccupied }

            if controls.isEmpty {
                // 耳机在，线控却没抓到 —— 说清楚，别让人以为按了没反应是自己的问题
                menu.addItem(disabledItem("未检测到线控按键"))
            }
            for device in controls {
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
        micItem.submenu = micMenu
        micItem.title = "麦克风输入：\(current?.name ?? "未知")"
        menu.addItem(micItem)

        menu.addItem(.separator())

        // 主开关
        let enabledItem = NSMenuItem(title: "启用", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = Settings.shared.enabled ? .on : .off
        menu.addItem(enabledItem)

        // 语音输入法和触发方式同属「会随场景换」的那一类（想用哪家的识别就切哪家），
        // 所以同样给一个子菜单，不埋进设置窗口。
        let voiceMethods = InputMethodCatalog.voiceInputMethods()
        if !voiceMethods.isEmpty {
            let currentID = Settings.shared.voiceInputMethodID
            let currentName = currentID.flatMap { id in voiceMethods.first { $0.id == id }?.name }
            let imeItem = NSMenuItem(title: "语音输入法：\(currentName ?? "不指定")",
                                     action: nil, keyEquivalent: "")
            let imeMenu = NSMenu()

            let noneItem = NSMenuItem(title: "不指定（只对当前输入法发触发键）",
                                      action: #selector(selectVoiceInputMethod(_:)), keyEquivalent: "")
            noneItem.target = self
            noneItem.representedObject = ""
            noneItem.state = (currentID == nil) ? .on : .off
            imeMenu.addItem(noneItem)
            imeMenu.addItem(.separator())

            for ime in voiceMethods {
                let item = NSMenuItem(title: ime.name,
                                      action: #selector(selectVoiceInputMethod(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ime.id
                item.state = (ime.id == currentID) ? .on : .off
                imeMenu.addItem(item)
            }
            imeItem.submenu = imeMenu
            menu.addItem(imeItem)

            // 选了输入法却没开全局快捷键，等于只有插耳机时能用，容易以为是坏的
            if currentID != nil, !Settings.shared.hotKeyEnabled {
                menu.addItem(disabledItem("　未开启键盘快捷键，仅耳机线控可触发"))
            }
        }

        // 触发方式放菜单里：它是会随场景换的东西（安静场合按住说话，
        // 长段口述切成按一下），埋在设置窗口里够不着。
        // 触发键则相反——快捷键是录制出来的，菜单承载不了录制交互，只读显示。
        let mode = Settings.shared.triggerMode
        let modeItem = NSMenuItem(title: "触发方式：\(mode.shortTitle)", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for candidate in TriggerMode.allCases {
            let item = NSMenuItem(title: candidate.title,
                                  action: #selector(selectTriggerMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = (candidate == mode) ? .on : .off
            modeMenu.addItem(item)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(disabledItem("触发键：\(Settings.shared.triggerShortcut.displayString)"))

        // 缺权限时才在菜单里露出入口。这是异常状态，值得占一行；
        // 都授权了就不必——设置窗口里有完整的权限页。
        if let missing = missingPermissionNames {
            menu.addItem(.separator())
            let permItem = NSMenuItem(title: "缺少\(missing)权限，点此处理",
                                      action: #selector(openPermissionsPane(_:)), keyEquivalent: "")
            permItem.target = self
            menu.addItem(permItem)
        }

        menu.addItem(.separator())

        let diagItem = NSMenuItem(title: "事件监视器…", action: #selector(openDiagnostics(_:)), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)

        // 检查更新和关于都并进设置窗口了，这里只留一个入口
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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
        // USB 耳机的插拔在 HID 这一路也会到，交给聚合器去重
        refreshHeadsetPresence()
    }

    func headsetDeviceRemoved(_ product: String) {
        // 拔出瞬间可能正按着中键。那次「松开」永远不会来，
        // 不在这里释放，触发键就永久卡在按下状态。
        // 不等聚合器：那要等随后的 devicesChanged，键会多卡一个来回。
        ptt.forceRelease(reason: "耳机拔出")
        updateIcon()
    }

    func headsetLog(_ message: String) {
        diagnostics.append(message)
    }
}
