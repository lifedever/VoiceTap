import Carbon.HIToolbox
import Cocoa

/// 合成键盘事件，模拟「按住 / 松开」触发键。
///
/// 全部 post 到 `.cghidEventTap`——注入在最底层的事件流，
/// 尽可能接近真实键盘，让输入法的长按检测认得。
enum KeySynthesizer {

    /// 打在自己合成的事件上的记号。
    ///
    /// 全局热键的 tap 和这里注入的事件在同一层（HID）。不打记号的话，我们合成的
    /// 触发键会被自己的 tap 再抓一次 —— 而抓到的处理又是「切换 + 合成」，
    /// 于是无限套娃，键盘直接失去响应。`eventSourceUserData` 是事件自带的
    /// 64 位用户字段，系统不碰它，正好用来认自己人。
    static let syntheticMarker: Int64 = 0x564F_4943_4554_4150  // "VOICETAP"

    /// 这个事件是我们自己发出去的吗
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }

    /// 合成事件统一用这一个 source，记号打在 **source** 上。
    ///
    /// 关键：`eventSourceUserData` 的权威来源是发出事件的那个 source，
    /// 往事件对象上写在 post 时会被 source 自己的值（默认 0）盖掉——
    /// 记号等于没打，我们的 tap 认不出自己合成的事件，于是把它当成一次新的
    /// 按键去匹配。热键和触发键不是同一个键时，合成的触发键正好被判成
    /// 「热键松开」并被**吞掉**，输入法永远收不到；两者是同一个键时又恰好
    /// 匹配成「状态没变」而放行。这正是「按了有时有反应有时没有」的来源。
    /// 每次现建一个：`CGEventSource` 不是 Sendable，存成全局常量在 Swift 6 下
    /// 直接编译不过。创建开销可以忽略，换来的是不用给并发检查开后门。
    private static func source() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = syntheticMarker
        return source
    }

    private static func post(_ event: CGEvent) {
        // source 上已经带了记号，这里再写一次纯属双保险
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
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
        post(event)
    }

    private static func postKey(_ keyCode: UInt16, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source(),
                                  virtualKey: CGKeyCode(keyCode),
                                  keyDown: down) else { return }
        event.flags = flags
        post(event)
    }

    private static func representativeKey(for flags: CGEventFlags) -> CGKeyCode {
        if flags.contains(.maskSecondaryFn) { return CGKeyCode(kVK_Function) }
        if flags.contains(.maskCommand) { return CGKeyCode(kVK_Command) }
        if flags.contains(.maskAlternate) { return CGKeyCode(kVK_Option) }
        if flags.contains(.maskControl) { return CGKeyCode(kVK_Control) }
        if flags.contains(.maskShift) { return CGKeyCode(kVK_Shift) }
        return CGKeyCode(kVK_Function)
    }

    /// 在用户**已经按着**这个键的情况下，让输入法看到一次「刚按下」。
    ///
    /// 场景：按住说话模式不吞原始按键（吞了系统的单击行为就废了），所以用户
    /// 真按下那一下时目标输入法还没被激活，它以「我不是当前输入法」忽略掉了。
    /// 等我们切换完再补一个 down 是没用的——系统的修饰键状态本来就是按下，
    /// 这一发没有状态变化，输入法看不见（实测：麦克风纹丝不动）。
    ///
    /// 必须先发 `up` 造出一次跳变，再发 `down`，它才认得这是新的一次按下。
    /// 中间那个 `up` 不会被系统误判成单击——合成的事件根本不触发 fn 的系统行为。
    @MainActor
    static func pressWithStateJump(_ shortcut: Shortcut, then completion: @escaping @MainActor () -> Void) {
        guard !shortcut.isEmpty else { completion(); return }
        release(shortcut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            MainActor.assumeIsolated {
                press(shortcut)
                completion()
            }
        }
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
            post(cgEvent)
        }
    }
}
