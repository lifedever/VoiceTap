import Carbon.HIToolbox
import Cocoa

// MARK: - C 回调
//
// 文件级 nonisolated 函数，不能写成方法内的闭包字面量：Swift 6 会把它推断为
// MainActor 隔离，@convention(c) thunk 里注入的 executor 检查在事件回调重入时
// 可能 EXC_BAD_ACCESS。和 ShortcutRecorderView 是同一条约束。

private func globalHotKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotKey>.fromOpaque(refcon).takeUnretainedValue()

    // 系统会因超时或用户输入禁用 tap。不重新启用的话热键会静默失效
    // ——按键毫无反应且不报错，是最难被联想到的一类故障。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    // 自己合成的触发键必须放行。拦下来的话「拦截 → 切换 → 合成」会喂给自己，
    // 无限套娃直到键盘完全失去响应。
    guard !KeySynthesizer.isSynthetic(event) else { return Unmanaged.passUnretained(event) }

    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    let swallow = monitor.handleTapEvent(type: type, keyCode: keyCode, flags: event.flags)
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// 监听一个全局快捷键，在任何 App 里按下都能触发语音输入。
///
/// fn 走 `flagsChanged`，`NSEvent` 那条路一条都收不到（约束 7），所以只能挂
/// EventTap。
///
/// ## 吞不吞是每次现算的
///
/// tap 固定建在 HID 层 `.defaultTap`（输入法自己的 tap 也在这一层且更早注册，
/// 站不到它前面就截不住），但是否真的吞掉逐次判断，见 `shouldSwallow`：
///
/// - **当前输入法 == 目标** → 放行。它自己会响应，我们不插手；这样那个键
///   原本的系统行为（单点换输入法等）也保住了。长按时无需合成任何东西。
/// - **当前输入法 != 目标** → 吞掉，抢在它前面。否则当前输入法会先响应，
///   于是「选了豆包，按 fn 弹出来的却是微信输入法」。吞掉之后借用目标输入法，
///   再合成触发键发给它。
/// - **轻点切换** → 一律吞：那个模式里单击就是功能本身。
@MainActor
final class GlobalHotKey {

    /// 按下 / 松开热键。第二个参数是这一下有没有被我们吞掉——
    /// 吞了的话那个键在系统眼里并没有被按下，PTT 发键的方式要跟着变。
    var onHotKey: ((Bool, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isRunning = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var shortcut: Shortcut = .fnOnly
    /// tap 建成了「有能力吞事件」的类型吗。真正吞不吞每次现算，见 `shouldSwallow`。
    private var canSwallow = false

    /// 这一下要不要吞掉。
    ///
    /// 关键在于**当前输入法自己可能也在抢这个键**：微信输入法的「按住说话」就是
    /// fn，而且它的 tap 在 HID 层、比我们先注册。放行的话它会在我们之前就开始
    /// 录音——于是「选了豆包，按 fn 却弹出微信输入法」。
    ///
    /// 所以按当前输入法分两种：
    /// - **当前就是目标输入法** → 放行。它自己会响应，我们不必插手；
    ///   而且放行才能保住这个键原本的系统行为（单点换输入法等）。
    /// - **当前不是目标** → 吞掉。必须抢在当前输入法前面把这一下截住，
    ///   否则它先响应，我们借谁都没用。
    ///
    /// 轻点切换模式一律吞：那个模式里单击就是功能本身。
    private var shouldSwallow: Bool {
        guard canSwallow else { return false }
        if Settings.shared.triggerMode == .toggle { return true }
        guard let target = Settings.shared.voiceInputMethodID else { return false }
        return InputMethodCatalog.currentID() != target
    }
    /// 热键正被按着。纯修饰键的 flagsChanged 只报「现在有哪些修饰键」，
    /// 不报是哪一个变了，得自己记住上一拍的状态才能分出按下沿和抬起沿。
    private var isDown = false

    // MARK: 生命周期

    /// tap 一律建在 HID 层、且具备吞事件的能力——因为目标输入法自己的 tap
    /// 也在 HID 层，我们必须能抢在它前面。**真正吞不吞每次现算**（`shouldSwallow`），
    /// 不需要吞的时候原样放行，那个键的系统行为就还在。
    func start(shortcut: Shortcut) {
        stop()
        guard !shortcut.isEmpty else {
            log("全局快捷键未设置，不启动监听")
            return
        }
        self.shortcut = shortcut

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // 必须是 HID 层 + headInsert：输入法自己的 tap 也挂在 HID 层且更早注册，
        // 只有站在它前面才可能截住那一下。Session 层来不及——那时它已经响应了。
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: globalHotKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate 失败几乎总是「输入监控」没授权
            log("⚠️ 全局快捷键启动失败：缺少「输入监控」权限")
            return
        }

        canSwallow = true
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        log("全局快捷键已启用：\(shortcut.displayString)")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isDown = false
        isRunning = false
        canSwallow = false
    }

    nonisolated func reenableTap() {
        Task { @MainActor in
            guard let tap = self.eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            self.log("全局快捷键的事件通道被系统关闭，已重新启用")
        }
    }

    // MARK: 事件匹配

    /// 返回是否吞掉这个事件。
    nonisolated func handleTapEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        MainActor.assumeIsolated {
            matches(type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func matches(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let normalized = Shortcut.normalizeCG(flags)

        if shortcut.isModifierOnly {
            // 纯修饰键（典型的就是单独一个 fn）：只有 flagsChanged，永远等不到 keyDown
            guard type == .flagsChanged else { return false }
            let nowDown = normalized == shortcut.modifiers
            guard nowDown != isDown else { return false }   // 状态没变，别重复上报
            isDown = nowDown
            let swallow = shouldSwallow
            dispatch(nowDown, swallowed: swallow)
            return swallow
        }

        // 修饰键 + 主键
        guard keyCode == shortcut.keyCode, normalized == shortcut.modifiers else { return false }
        switch type {
        case .keyDown:
            guard !isDown else { return shouldSwallow }   // 系统的按键重复，不重复上报
            isDown = true
            let downSwallow = shouldSwallow
            dispatch(true, swallowed: downSwallow)
            return downSwallow
        case .keyUp:
            guard isDown else { return false }
            isDown = false
            let upSwallow = shouldSwallow
            dispatch(false, swallowed: upSwallow)
            return upSwallow
        default:
            return false
        }
    }



    /// 动作必须跳出 tap 回调栈再做。
    ///
    /// 回调是同步调在事件派发路径上的，而我们要做的事里包含 `CGEvent.post`——
    /// 在还没把当前事件交还给系统时就往同一条流里注入新事件，注入的那个会被
    /// 丢掉。表现为：切换输入法、写日志全都正常（VoiceTap 这边完全看不出问题），
    /// 唯独输入法收不到触发键，于是「按了没反应」时高时低地随机出现。
    ///
    /// 这里已经在主线程（tap 挂在主 runloop 上），`async` 只是把动作推到当前
    /// 回调返回之后执行；派发顺序仍由主队列保证，按下一定排在松开前面。
    private func dispatch(_ pressed: Bool, swallowed: Bool) {
        log("全局快捷键 \(shortcut.displayString) \(pressed ? "按下" : "松开")\(swallowed ? "（已截住）" : "")")
        DispatchQueue.main.async { [weak self] in
            self?.onHotKey?(pressed, swallowed)
        }
    }

    private func log(_ message: String) { onLog?(message) }
}
