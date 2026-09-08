import Carbon.HIToolbox
import Cocoa

/// 一个快捷键。
///
/// VoiceTap 并不知道输入法的存在——它只是「按下某个键」，谁监听那个键谁响应。
/// 所以这里能录任意组合，只要和输入法里设的那个一致就能联动，
/// 不限于某一款输入法。
struct Shortcut: Codable, Equatable {

    /// 主键的 virtual key code。纯修饰键组合（如单独的 fn）时为 nil。
    var keyCode: UInt16?

    /// 修饰键集合，存 `CGEventFlags` 的 rawValue
    var modifiers: UInt64

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    var isModifierOnly: Bool { keyCode == nil }

    /// 微信输入法「按住说话」的出厂设置就是单独一个 fn，作为默认值最省事
    static let fnOnly = Shortcut(keyCode: nil, modifiers: CGEventFlags.maskSecondaryFn.rawValue)

    var isEmpty: Bool { keyCode == nil && modifiers == 0 }

    /// 拿它当**全局热键**会不会误伤普通打字。
    ///
    /// 全局热键是靠吞掉事件实现的（不吞的话输入法会在切换前就收到那一下）。
    /// 单独一个 ⌘ / ⇧ / ⌃ / ⌥ 被吞掉，等于系统再也看不到这个修饰键被按下，
    /// ⌘C、⌘V 这类组合键会整个失效——而且失效时毫无线索。
    ///
    /// fn 不在此列：以它开头的组合键极少，且语音输入法本来就占用着它。
    var isRiskyAsHotKey: Bool {
        guard isModifierOnly, modifiers != 0 else { return false }
        return modifiers != CGEventFlags.maskSecondaryFn.rawValue
    }

    // MARK: 显示

    /// 形如 "fn"、"⌃⌥⌘Z"、"⌥空格"
    var displayString: String {
        var result = ""
        let f = flags
        if f.contains(.maskSecondaryFn) { result += "fn " }
        if f.contains(.maskControl) { result += "⌃" }
        if f.contains(.maskAlternate) { result += "⌥" }
        if f.contains(.maskShift) { result += "⇧" }
        if f.contains(.maskCommand) { result += "⌘" }
        if let keyCode { result += Self.keyName(for: keyCode) }
        return result.isEmpty ? "未设置" : result.trimmingCharacters(in: .whitespaces)
    }

    /// 键码转显示名。
    ///
    /// 字符类按**当前键盘布局**反查，不硬编码 ANSI 位置——
    /// 硬编码的话 Dvorak / Colemak / AZERTY 用户看到的键名会和实际按的对不上。
    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "键\(keyCode)" }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return "键\(keyCode)" }

            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,                       // 不带修饰键，取键帽本身的字符
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return "键\(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "空格",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    // MARK: 从事件构造

    /// 只保留我们关心的修饰位，丢掉 numpad / 大小写锁等噪声位
    static func normalize(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        var result: CGEventFlags = []
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result.rawValue
    }

    /// CGEvent 版本。录制走 EventTap，拿到的是 `CGEventFlags`。
    static func normalizeCG(_ flags: CGEventFlags) -> UInt64 {
        var result: CGEventFlags = []
        if flags.contains(.maskSecondaryFn) { result.insert(.maskSecondaryFn) }
        if flags.contains(.maskControl) { result.insert(.maskControl) }
        if flags.contains(.maskAlternate) { result.insert(.maskAlternate) }
        if flags.contains(.maskShift) { result.insert(.maskShift) }
        if flags.contains(.maskCommand) { result.insert(.maskCommand) }
        return result.rawValue
    }
}
