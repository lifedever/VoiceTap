import Cocoa
import Carbon.HIToolbox

/// PTT 触发键。对应输入法里设置的「按住说话」快捷键。
enum TriggerKey: String, CaseIterable, Codable {
    case fn
    case rightCommand
    case rightOption
    case ctrlOptCmdZ
    case ctrlOptCmdSpace

    var label: String {
        switch self {
        case .fn: return "fn（微信输入法默认）"
        case .rightCommand: return "右 Command"
        case .rightOption: return "右 Option"
        case .ctrlOptCmdZ: return "⌃⌥⌘Z"
        case .ctrlOptCmdSpace: return "⌃⌥⌘Space"
        }
    }

    /// 需要用户去输入法里把 PTT 快捷键改成这个值吗？
    var requiresIMEConfig: Bool { self != .fn }
}

/// 合成键盘事件，模拟「按住 / 松开」触发键。
///
/// 全部 post 到 `.cghidEventTap`——注入在最底层的事件流，
/// 尽可能接近真实键盘，让输入法的长按检测认得。
enum KeySynthesizer {

    private static func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    // MARK: 触发键按下 / 松开

    static func press(_ key: TriggerKey) {
        switch key {
        case .fn:
            postModifierOnly(virtualKey: CGKeyCode(kVK_Function), flags: .maskSecondaryFn, down: true)
        case .rightCommand:
            postModifierOnly(virtualKey: CGKeyCode(kVK_RightCommand), flags: .maskCommand, down: true)
        case .rightOption:
            postModifierOnly(virtualKey: CGKeyCode(kVK_RightOption), flags: .maskAlternate, down: true)
        case .ctrlOptCmdZ:
            postCombo(virtualKey: CGKeyCode(kVK_ANSI_Z), flags: comboFlags, down: true)
        case .ctrlOptCmdSpace:
            postCombo(virtualKey: CGKeyCode(kVK_Space), flags: comboFlags, down: true)
        }
    }

    static func release(_ key: TriggerKey) {
        switch key {
        case .fn:
            postModifierOnly(virtualKey: CGKeyCode(kVK_Function), flags: [], down: false)
        case .rightCommand:
            postModifierOnly(virtualKey: CGKeyCode(kVK_RightCommand), flags: [], down: false)
        case .rightOption:
            postModifierOnly(virtualKey: CGKeyCode(kVK_RightOption), flags: [], down: false)
        case .ctrlOptCmdZ:
            postCombo(virtualKey: CGKeyCode(kVK_ANSI_Z), flags: comboFlags, down: false)
        case .ctrlOptCmdSpace:
            postCombo(virtualKey: CGKeyCode(kVK_Space), flags: comboFlags, down: false)
        }
    }

    private static let comboFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    /// 清空所有修饰键状态。
    ///
    /// 上次进程如果是崩溃/被强杀退出的，`applicationWillTerminate` 不会执行，
    /// 合成出去的修饰键就永远停在按下状态——用户会发现整个系统的键盘行为错乱，
    /// 且完全想不到是这个小工具干的。启动时无条件清一次，成本几乎为零。
    /// 只发 flags 归零，不发任何孤立的 keyUp，对没卡住的情况无副作用。
    static func clearModifiers() {
        guard let event = CGEvent(keyboardEventSource: source(),
                                  virtualKey: CGKeyCode(kVK_Function),
                                  keyDown: false) else { return }
        event.type = .flagsChanged
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    /// 纯修饰键（fn / 左右 Command 之类）：按下抬起产生的是 flagsChanged，不是 keyDown。
    private static func postModifierOnly(virtualKey: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source(), virtualKey: virtualKey, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// 修饰键 + 主键：先带齐 flags 再 post keyDown/keyUp。
    private static func postCombo(virtualKey: CGKeyCode, flags: CGEventFlags, down: Bool) {
        if down {
            // 先让修饰键落地，再按主键，顺序与真实键盘一致
            if let mod = CGEvent(keyboardEventSource: source(), virtualKey: CGKeyCode(kVK_Control), keyDown: true) {
                mod.type = .flagsChanged
                mod.flags = flags
                mod.post(tap: .cghidEventTap)
            }
        }

        guard let event = CGEvent(keyboardEventSource: source(), virtualKey: virtualKey, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)

        if !down {
            if let mod = CGEvent(keyboardEventSource: source(), virtualKey: CGKeyCode(kVK_Control), keyDown: false) {
                mod.type = .flagsChanged
                mod.flags = []
                mod.post(tap: .cghidEventTap)
            }
        }
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
