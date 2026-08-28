import Carbon.HIToolbox
import Cocoa

/// 合成键盘事件，模拟「按住 / 松开」触发键。
///
/// 全部 post 到 `.cghidEventTap`——注入在最底层的事件流，
/// 尽可能接近真实键盘，让输入法的长按检测认得。
enum KeySynthesizer {

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    // MARK: 触发键按下 / 松开

    static func press(_ shortcut: Shortcut) {
        guard !shortcut.isEmpty else { return }

        // 修饰键先落地，顺序与真实键盘一致
        postModifiers(shortcut.flags)

        if let keyCode = shortcut.keyCode {
            postKey(keyCode, flags: shortcut.flags, down: true)
        }
    }

    static func release(_ shortcut: Shortcut) {
        guard !shortcut.isEmpty else { return }

        if let keyCode = shortcut.keyCode {
            postKey(keyCode, flags: shortcut.flags, down: false)
        }

        // 最后清空修饰键状态
        postModifiers([])
    }

    /// 纯修饰键的按下/抬起产生的是 flagsChanged，不是 keyDown。
    ///
    /// virtualKey 取修饰键集合里的一个代表键；系统看的是事件上的 flags，
    /// 但仍需要一个合法的键码，否则事件会被丢弃。
    private static func postModifiers(_ flags: CGEventFlags) {
        let representative = representativeKey(for: flags)
        guard let event = CGEvent(keyboardEventSource: source(),
                                  virtualKey: representative,
                                  keyDown: !flags.isEmpty) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func postKey(_ keyCode: UInt16, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source(),
                                  virtualKey: CGKeyCode(keyCode),
                                  keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func representativeKey(for flags: CGEventFlags) -> CGKeyCode {
        if flags.contains(.maskSecondaryFn) { return CGKeyCode(kVK_Function) }
        if flags.contains(.maskCommand) { return CGKeyCode(kVK_Command) }
        if flags.contains(.maskAlternate) { return CGKeyCode(kVK_Option) }
        if flags.contains(.maskControl) { return CGKeyCode(kVK_Control) }
        if flags.contains(.maskShift) { return CGKeyCode(kVK_Shift) }
        return CGKeyCode(kVK_Function)
    }

    /// 清空所有修饰键状态。
    ///
    /// 上次进程如果是崩溃/被强杀退出的，`applicationWillTerminate` 不会执行，
    /// 合成出去的修饰键就永远停在按下状态——用户会发现整个系统的键盘行为错乱，
    /// 且完全想不到是这个小工具干的。启动时无条件清一次，成本几乎为零。
    /// 只发 flags 归零，不发任何孤立的 keyUp，对没卡住的情况无副作用。
    static func clearModifiers() {
        postModifiers([])
    }

    // MARK: 媒体键

    /// 独占线控后，用它把「单击 = 播放/暂停」补回去。
    static func postPlayPause() {
        postMediaKey(NX_KEYTYPE_PLAY)
    }

    /// 独占会把线控的音量键一起吞掉，同样要补回去，否则耳机上调不了音量。
    static func postVolumeUp() {
        postMediaKey(NX_KEYTYPE_SOUND_UP)
    }

    static func postVolumeDown() {
        postMediaKey(NX_KEYTYPE_SOUND_DOWN)
    }

    private static func postMediaKey(_ keyCode: Int32) {
        for down in [true, false] {
            let flags = down ? 0xA00 : 0xB00
            let data1 = Int((Int(keyCode) << 16) | flags)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ), let cgEvent = event.cgEvent else { continue }
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
