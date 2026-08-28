import Cocoa

/// 把线控按键翻译成「按住说话」动作。
///
/// 语义：
///   - 长按中键  → 按住触发键（输入法开始录音），松开 → 释放触发键（出字）
///   - 单击中键  → 播放/暂停（独占模式下由我们合成补回）
///   - 音量键    → 独占模式下同样要合成补回，否则音量调节会失效
@MainActor
final class PTTController {

    /// PTT 最长持续时间。超过就强制释放——防止任何异常路径把修饰键永久按住，
    /// 那会让整个系统的键盘输入错乱，属于必须兜住的故障。
    private static let maxPTTDuration: TimeInterval = 120

    private(set) var isPTTActive = false
    private var isButtonDown = false
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

    // MARK: 长按

    private func startLongPressTimer() {
        cancelLongPressTimer()
        let threshold = Settings.shared.longPressThreshold
        longPressTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginPTT() }
        }
    }

    private func cancelLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func beginPTT() {
        guard !isPTTActive, isButtonDown else { return }
        isPTTActive = true

        let key = Settings.shared.triggerKey
        KeySynthesizer.press(key)
        log("长按 → 按下 \(key.label)，开始说话")
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

        let key = Settings.shared.triggerKey
        KeySynthesizer.release(key)
        log("\(reason) → 释放 \(key.label)")
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
