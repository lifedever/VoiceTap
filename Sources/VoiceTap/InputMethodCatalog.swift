import AppKit
import Carbon

/// 一个能被「借用」来做语音输入的输入法。
struct VoiceInputMethod: Identifiable, Equatable, Hashable {
    /// TISInputSourceID，如 `com.tencent.inputmethod.wetype.pinyin`。
    /// 存配置、跨启动查找都用它——反向 DNS 字符串永不本地化。
    let id: String
    /// 本地化显示名。**只用来显示**，不做任何判断。
    let name: String
    let bundleID: String

    static func == (a: VoiceInputMethod, b: VoiceInputMethod) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// 枚举本机装了哪些「有语音输入能力」的输入法。
///
/// 判据是 bundle 里有没有 `NSMicrophoneUsageDescription`——想录音就必须声明它，
/// 这是系统强制的，声明了才可能有语音功能。**不硬编码 bundle ID 名单**：
/// 那种名单只能覆盖写它的那天装了什么，用户之后装的搜狗 / 讯飞一律漏掉，
/// 且漏掉时是静默的（列表里就是没有，没有任何报错）。
///
/// 同理不看显示名（`微信输入法` / `WeType` 随系统语言变），不看进程名。
@MainActor
enum InputMethodCatalog {

    /// 输入法的安装位置由系统规定，只有这两处。扫目录比用 bundle ID 反查可靠——
    /// `NSWorkspace.urlForApplication` 对不在 /Applications 下的 bundle 并不保证找得到。
    private static var inputMethodBundles: [String: Bundle] {
        var map: [String: Bundle] = [:]
        let dirs = [
            "/Library/Input Methods",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Input Methods"),
        ]
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(item)
                guard let bundle = Bundle(path: path), let bid = bundle.bundleIdentifier else { continue }
                map[bid] = bundle
            }
        }
        return map
    }

    /// 本机所有可选中、且具备语音能力的输入法。
    static func voiceInputMethods() -> [VoiceInputMethod] {
        let bundles = inputMethodBundles
        return allSelectableSources().compactMap { source in
            guard let id = property(source, kTISPropertyInputSourceID),
                  let bundleID = property(source, kTISPropertyBundleID),
                  let bundle = bundles[bundleID],
                  bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            else { return nil }
            let name = property(source, kTISPropertyLocalizedName) ?? id
            return VoiceInputMethod(id: id, name: name, bundleID: bundleID)
        }
    }

    /// 某个输入源现在还在不在（用户可能把它从系统设置里删了）
    static func exists(_ id: String) -> Bool {
        allSelectableSources().contains { property($0, kTISPropertyInputSourceID) == id }
    }

    static func displayName(for id: String) -> String? {
        guard let s = source(withID: id) else { return nil }
        return property(s, kTISPropertyLocalizedName)
    }

    static func bundleID(for id: String) -> String? {
        guard let s = source(withID: id) else { return nil }
        return property(s, kTISPropertyBundleID)
    }

    /// 这个输入法现在有没有摆在屏幕上的浮窗（语音面板、候选条…）。
    ///
    /// 用来判断「它到底忙完了没有」——比麦克风是否占用准：录音停了不等于
    /// 字已经送出去，浮窗还在就说明它还在收尾。
    ///
    /// 只看 owner 的 PID 和窗口尺寸，不读 `kCGWindowName`（那个要屏幕录制权限）。
    /// 尺寸下限用来滤掉输入法常驻的 1x1 占位窗。
    static func hasVisibleWindow(bundleID: String) -> Bool {
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .map(\.processIdentifier)
        guard !pids.isEmpty else { return false }

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double
            else { return false }
            return width > 30 && height > 20
        }
    }

    /// 当前输入法的 TISInputSourceID。
    static func currentID() -> String? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return property(cur, kTISPropertyInputSourceID)
    }

    /// 切换到指定输入法。实测同步生效、耗时 6~7ms。
    @discardableResult
    static func select(_ id: String) -> Bool {
        guard let s = source(withID: id) else { return false }
        return TISSelectInputSource(s) == noErr
    }

    // MARK: 内部

    private static func allSelectableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]
        else { return [] }
        return list.filter { s in
            guard let type = property(s, kTISPropertyInputSourceType), type.contains("Keyboard") else { return false }
            return boolProperty(s, kTISPropertyInputSourceIsSelectCapable)
        }
    }

    private static func source(withID id: String) -> TISInputSource? {
        allSelectableSources().first { property($0, kTISPropertyInputSourceID) == id }
    }

    private static func property(_ s: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func boolProperty(_ s: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(s, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
}
