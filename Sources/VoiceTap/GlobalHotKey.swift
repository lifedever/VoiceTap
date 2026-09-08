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
/// EventTap。层的选择见下——两种模式挂的层和类型都不同。
///
/// ## 两种模式挂的是不同类型的 tap
///
/// - **按住说话** → Session 层 + `.listenOnly`。这个模式不需要吞事件，用最轻的
///   方式旁观即可，也最不容易误伤别的键。
///   原始按键放行之后，短按由系统照常处理；长按则借用输入法，再用
///   `KeySynthesizer.pressWithStateJump` 制造一次它能看见的「刚按下」。
///
/// - **轻点切换** → `.defaultTap`，必须吞。那个模式里单击就是功能本身，
///   放行的话按一下会同时触发系统行为和语音输入。代价就是这个模式下
///   热键的系统单击行为救不回来（合成的按键触发不了它）。
@MainActor
final class GlobalHotKey {

    /// 按下 / 松开热键。松开只在「按住说话」模式下有意义。
    var onHotKey: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isRunning = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var shortcut: Shortcut = .fnOnly
    /// tap 是不是以「可吞事件」的方式建的。**只有轻点切换模式才是真**——
    /// 那个模式里单击就是功能本身，不吞的话按一下会同时触发系统行为和语音输入。
    /// 按住说话模式用 listenOnly，见 `start(shortcut:swallows:)` 的说明。
    private var swallowsEvents = false
    /// 热键正被按着。纯修饰键的 flagsChanged 只报「现在有哪些修饰键」，
    /// 不报是哪一个变了，得自己记住上一拍的状态才能分出按下沿和抬起沿。
    private var isDown = false

    // MARK: 生命周期

    /// - Parameter swallows: 要不要具备**吞掉事件**的能力。
    ///
    ///   按住说话模式本来就不需要吞，所以给它 `.listenOnly` + Session 层，
    ///   按「最小干预」原则取的保守值。
    func start(shortcut: Shortcut, swallows: Bool) {
        stop()
        guard !shortcut.isEmpty else {
            log("全局快捷键未设置，不启动监听")
            return
        }
        self.shortcut = shortcut
        self.swallowsEvents = swallows

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // 按「最小干预」选层，不是因为它修好过什么（曾经误以为 HID 层的
        // defaultTap 会废掉 fn 的系统行为，后来发现 VoiceTap 完全退出时同样复现，
        // 那条结论未证实、已撤销）：
        //   .cgSessionEventTap 看得到 fn 却吞不掉它的系统行为（约束 7 记的那个
        //     「缺点」），对只想旁观的按住说话模式正好，也最不容易误伤别的键。
        // 只有必须吞事件的轻点切换才回到 HID 层。
        guard let tap = CGEvent.tapCreate(
            tap: swallows ? .cghidEventTap : .cgSessionEventTap,
            place: .headInsertEventTap,
            options: swallows ? .defaultTap : .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: globalHotKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate 失败几乎总是「输入监控」没授权
            log("⚠️ 全局快捷键启动失败：缺少「输入监控」权限")
            return
        }

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
            dispatch(nowDown)
            return swallowsEvents
        }

        // 修饰键 + 主键
        guard keyCode == shortcut.keyCode, normalized == shortcut.modifiers else { return false }
        switch type {
        case .keyDown:
            guard !isDown else { return swallowsEvents }   // 系统的按键重复，不重复上报
            isDown = true
            dispatch(true)
            return swallowsEvents
        case .keyUp:
            guard isDown else { return false }
            isDown = false
            dispatch(false)
            return swallowsEvents
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
    private func dispatch(_ pressed: Bool) {
        log("全局快捷键 \(shortcut.displayString) \(pressed ? "按下" : "松开")")
        DispatchQueue.main.async { [weak self] in
            self?.onHotKey?(pressed)
        }
    }

    private func log(_ message: String) { onLog?(message) }
}
