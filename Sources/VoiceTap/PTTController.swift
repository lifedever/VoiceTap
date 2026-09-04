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

    private var isButtonDown = false
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

    private func beginPTT(reason: String) {
        guard !isPTTActive else { return }
        isPTTActive = true

        let key = Settings.shared.triggerShortcut
        KeySynthesizer.press(key)
        log("\(reason) → 按下 \(key.displayString)，开始说话")
        onStateChange?(true)

        // 安全阀
        safetyTimer = Timer.scheduledTimer(withTimeInterval: Self.maxPTTDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endPTT(reason: "超时保护") }
        }
    }

    private func endPTT(reason: String) {
        guard isPTTActive else { return }
        isPTTActive = false

        safetyTimer?.invalidate()
        safetyTimer = nil

        let key = Settings.shared.triggerShortcut
        KeySynthesizer.release(key)
        log("\(reason) → 释放 \(key.displayString)")
        onStateChange?(false)
    }

    // MARK: 兜底释放
    //
    // 只要有任何一条路径让我们收不到「松开」事件（拔耳机、关开关、退出 app），
    // 触发键就会一直处于按下状态。所有这些出口都必须强制释放。

    /// 设备断开 / 功能关闭 / app 退出时调用
    func forceRelease(reason: String) {
        cancelLongPressTimer()
        isButtonDown = false
        if isPTTActive {
            endPTT(reason: reason)
        }
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
