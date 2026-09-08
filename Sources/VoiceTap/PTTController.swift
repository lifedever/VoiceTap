import Cocoa

/// 把线控按键翻译成语音输入动作。
///
/// 语义（`Settings.triggerMode` 二选一）：
///   - 按住说话：长按中键 → 按住触发键（输入法开始录音），松开 → 释放触发键（出字）；
///               单击中键 → 播放/暂停（独占模式下由我们合成补回）
///   - 切换：    轻点中键 → 按住触发键并保持，再轻点一下 → 释放。
///               单击已经被占用，这个模式下没有播放/暂停可补
///   - 音量键    → 两种模式相同，独占后都要合成补回，否则音量调节会失效
@MainActor
final class PTTController {

    /// PTT 最长持续时间。超过就强制释放——防止任何异常路径把修饰键永久按住，
    /// 那会让整个系统的键盘输入错乱，属于必须兜住的故障。
    /// 切换模式下它还兼职「忘记关」的兜底，因为那个模式没有「松手」这条自然出口。
    private static let maxPTTDuration: TimeInterval = 120

    /// 切换模式的去抖窗口。真人两次按键不可能快过这个数，
    /// HID 重复上报的 DOWN 则一定在几毫秒内。
    private static let toggleDebounce: TimeInterval = 0.25

    /// UP 事件丢失后的自愈窗口。见 `handleToggle`。
    /// 取得比「人按住线控不放」的时长长，才不会被按住时的重复上报误判成第二下。
    private static let toggleStuckRecovery: TimeInterval = 5.0

    private(set) var isPTTActive = false

    /// 触发前把目标输入法借过来，说完还回去。
    /// 输入法非激活时收到触发键会直接忽略，所以这一步不是优化而是前提。
    let inputMethodSwitcher = InputMethodSwitcher()

    private var isButtonDown = false
    /// 触发键当前是不是按下状态。切换输入法后 press 是延迟发的，
    /// 这段时间里 release 不能发——否则会凭空多出一个没有配对的抬起。
    private var triggerKeyIsDown = false
    /// 排队中的「等输入法就绪后按下触发键」
    private var pendingPress: DispatchWorkItem?
    /// 全局热键的长按判定
    private var hotKeyLongPressTimer: Timer?
    private var lastToggleAt: Date?
    private var longPressTimer: Timer?
    private var safetyTimer: Timer?

    var onStateChange: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    // MARK: 输入

    func handle(button: HeadsetButton, pressed: Bool) {
        switch button {
        case .playPause:
            handlePlayPause(pressed: pressed)
        case .volumeUp:
            // 独占后系统收不到了，替它补一发
            if pressed, Settings.shared.seizeDevice { KeySynthesizer.postVolumeUp() }
        case .volumeDown:
            if pressed, Settings.shared.seizeDevice { KeySynthesizer.postVolumeDown() }
        }
    }

    private func handlePlayPause(pressed: Bool) {
        switch Settings.shared.triggerMode {
        case .hold: handleHold(pressed: pressed)
        case .toggle: handleToggle(pressed: pressed)
        }
    }

    // MARK: 按住说话

    private func handleHold(pressed: Bool) {
        if pressed {
            // HID 有时会重复上报 DOWN，去重，否则会叠加计时器
            guard !isButtonDown else { return }
            isButtonDown = true
            startLongPressTimer()
        } else {
            guard isButtonDown else { return }
            isButtonDown = false
            cancelLongPressTimer()

            if isPTTActive {
                endPTT(reason: "松开")
            } else {
                // 没到长按阈值 = 单击
                if Settings.shared.seizeDevice && Settings.shared.singleClickPlayPause {
                    KeySynthesizer.postPlayPause()
                    log("单击 → 播放/暂停")
                }
            }
        }
    }

    // MARK: 切换

    /// 按下即翻转状态，松开什么都不做。
    ///
    /// 去重要同时挡住两种相反的故障，任一条漏掉都会让这个模式失效：
    ///
    /// - **同一次按压被上报多次** —— HID 是按 report 回调的，设备按住时周期性
    ///   发 report，同一个 DOWN 会重复到达。只看时间窗挡不住持续重复（窗口一过
    ///   就又翻一次），所以主判据是按下沿：`isButtonDown` 为真时不再翻转。
    /// - **UP 事件丢失** —— 只看按下沿的话 `isButtonDown` 会永远停在 true，
    ///   之后每一次按键都被吞掉，功能静默失效且不自愈。所以补一条恢复窗口：
    ///   距上次翻转超过 `toggleStuckRecovery` 就认这一下，无视残留的按下状态。
    private func handleToggle(pressed: Bool) {
        guard pressed else {
            isButtonDown = false
            return
        }

        let wasDown = isButtonDown
        isButtonDown = true

        let now = Date()
        let sinceLast = lastToggleAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard sinceLast >= Self.toggleDebounce else { return }
        guard !wasDown || sinceLast >= Self.toggleStuckRecovery else { return }
        lastToggleAt = now

        if isPTTActive {
            endPTT(reason: "再按一下")
        } else {
            beginPTT(reason: "按一下")
        }
    }

    // MARK: 长按

    private func startLongPressTimer() {
        cancelLongPressTimer()
        let threshold = Settings.shared.longPressThreshold
        longPressTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // 阈值到点时按钮可能已经松开（cancel 与 fire 的竞态）
                guard let self, self.isButtonDown else { return }
                self.beginPTT(reason: "长按")
            }
        }
    }

    private func cancelLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    /// - Parameter hotKeyStillHeld: 用户按着的那个键**没有被吞**，此刻仍以按下状态
    ///   躺在系统的事件流里（按住说话模式的全局热键就是这样）。这会改变发键方式：
    ///   系统状态里它已经是按下的，再补一个 down 没有状态变化，输入法看不见。
    private func beginPTT(reason: String, hotKeyStillHeld: Bool = false) {
        guard !isPTTActive else { return }
        isPTTActive = true

        // 顺序不能反：输入法非激活时会**直接忽略**触发键，而那一下没有任何补救
        // 机会（不像修饰键还能重发）。必须先把它借过来，再发键。
        var switched = false
        if let targetID = Settings.shared.voiceInputMethodID {
            switched = inputMethodSwitcher.borrow(targetID) == .switched
        }

        let key = Settings.shared.triggerShortcut
        // 用户按的键和要发给输入法的键是同一个，而且那一下没被吞——
        // 也就是说这个键此刻在系统眼里已经是按下状态
        let alreadyPhysicallyDown = hotKeyStillHeld && Settings.shared.hotKey == key

        // 没换输入法 + 同一个键 + 没吞事件 = 输入法早就收到用户真按的那一下了，
        // 我们再插一手只会把它已经开始的录音打断
        if !switched, alreadyPhysicallyDown {
            triggerKeyIsDown = false        // 不是我们发的，也就不该由我们释放
            log("\(reason) → 输入法已直接收到 \(key.displayString)")
            onStateChange?(true)
            startSafetyTimer()
            return
        }

        let sendPress: () -> Void = { [weak self] in
            guard let self else { return }
            if alreadyPhysicallyDown {
                // 先 up 造出跳变，输入法才认得这是「刚按下」
                KeySynthesizer.pressWithStateJump(key) { [weak self] in
                    guard let self, self.isPTTActive else { return }
                    self.triggerKeyIsDown = true
                    self.log("按下 \(key.displayString)，开始说话")
                }
            } else {
                KeySynthesizer.press(key)
                self.triggerKeyIsDown = true
                self.log("按下 \(key.displayString)，开始说话")
            }
        }

        if switched {
            // 刚切过去，得等它真正接管输入上下文，否则这一下会被静默丢掉
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isPTTActive else { return }   // 期间可能已经松开
                sendPress()
            }
            pendingPress = item
            DispatchQueue.main.asyncAfter(deadline: .now() + InputMethodSwitcher.readyDelay, execute: item)
            log("\(reason) → 已切换输入法，等它就绪")
        } else {
            log("\(reason) → 开始说话")
            sendPress()
        }
        onStateChange?(true)
        startSafetyTimer()
    }

    /// 兜底：任何异常路径都不能让触发键/借来的输入法永久卡住
    private func startSafetyTimer() {
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: Self.maxPTTDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endPTT(reason: "超时保护") }
        }
    }

    private func endPTT(reason: String) {
        guard isPTTActive else { return }
        isPTTActive = false

        safetyTimer?.invalidate()
        safetyTimer = nil

        // 触发键可能还在「等输入法就绪」的队列里没发出去。必须连这条一起取消，
        // 否则 release 先跑、press 后跑，键就永久卡在按下状态。
        pendingPress?.cancel()
        pendingPress = nil

        let key = Settings.shared.triggerShortcut
        if triggerKeyIsDown {
            KeySynthesizer.release(key)
            triggerKeyIsDown = false
            log("\(reason) → 释放 \(key.displayString)")
        } else {
            log("\(reason) → 结束（触发键尚未发出，无需释放）")
        }
        onStateChange?(false)

        // 不在这里立刻还：录音停止那一刻文字还没送进目标 App，而那条通道
        // 依赖「它仍是当前输入法」。由 switcher 等识别真正结束再还。
        inputMethodSwitcher.scheduleRestore()
    }

    // MARK: 全局快捷键

    /// 键盘上的全局快捷键触发。
    ///
    /// 按住说话模式下**必须**走长按阈值，而且短按要把那一下还给系统。
    /// 因为热键是靠吞掉原事件实现的，而 fn 这类键本身就有单击语义
    /// （切换输入法 / Emoji / 听写）——不区分的话，用户会发现"单击 fn 换输入法
    /// 突然失灵了"，而且完全联想不到是这个小工具干的。
    ///
    /// 线控那边的阈值区分的是「单击 = 播放/暂停」，这边区分的是「单击 = 系统功能」，
    /// 语义一致，所以共用 `longPressThreshold`。
    /// - Parameter swallowed: 这一下被我们吞掉了吗。吞了的话它在系统眼里
    ///   并没有被按下，合成触发键时就不需要「状态跳变」那套。
    func handleHotKey(pressed: Bool, swallowed: Bool) {
        switch Settings.shared.triggerMode {
        case .hold:
            if pressed {
                startHotKeyLongPress(swallowed: swallowed)
            } else {
                cancelHotKeyLongPress()
                if isPTTActive {
                    endPTT(reason: "快捷键松开")
                }
                // 短按不用管：这个模式下原始按键根本没被吞，系统自己会处理
                // 它的单击行为（fn 换输入法等）。曾经试过「吞掉再补发」，
                // 实测补发的 fn 不触发任何系统行为，那条路是死的。
            }
        case .toggle:
            // 松开不做事；按下沿的重复已由 GlobalHotKey 挡掉。
            // 这个模式下单击就是功能本身，没法再把它让给系统。
            guard pressed else { return }
            if isPTTActive { endPTT(reason: "快捷键再按一下") } else { beginPTT(reason: "快捷键按一下") }
        }
    }

    private func startHotKeyLongPress(swallowed: Bool) {
        cancelHotKeyLongPress()
        hotKeyLongPressTimer = Timer.scheduledTimer(
            withTimeInterval: Settings.shared.longPressThreshold, repeats: false
        ) { [weak self] _ in
            // 没吞的话这个键此刻仍以按下状态躺在事件流里，发键方式要跟着变
            Task { @MainActor in
                self?.beginPTT(reason: "快捷键长按", hotKeyStillHeld: !swallowed)
            }
        }
    }

    private func cancelHotKeyLongPress() {
        hotKeyLongPressTimer?.invalidate()
        hotKeyLongPressTimer = nil
    }

    // MARK: 兜底释放
    //
    // 只要有任何一条路径让我们收不到「松开」事件（拔耳机、关开关、退出 app），
    // 触发键就会一直处于按下状态。所有这些出口都必须强制释放。

    /// 设备断开 / 功能关闭 / app 退出时调用
    func forceRelease(reason: String) {
        cancelLongPressTimer()
        cancelHotKeyLongPress()
        isButtonDown = false
        if isPTTActive {
            endPTT(reason: reason)
        }
        // 借出去的输入法同样要还，而且这些路径不能再等麦克风——它们本身就是
        // 「收不到正常结束事件」的出口，等下去很可能永远等不到。
        // 借了不还 = 用户的输入法被永久改掉，正是这个功能最该避免的后果。
        inputMethodSwitcher.restoreNow(reason: reason)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
