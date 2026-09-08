import Foundation

/// 线控中键触发语音输入的方式。
enum TriggerMode: String, CaseIterable {
    /// 按住说话：按下开始，松开结束。手一直占着，但绝不会忘记关。
    case hold
    /// 轻点一下开始，再轻点一下结束。
    ///
    /// rawValue 保持 `toggle` 不动：老配置里存的就是这个字符串，改了会让
    /// 已经选过切换模式的用户悄悄退回按住说话。
    case toggle

    // 曾经有过第三种「按住片刻切换」，靠的是「rcd 只把短按当播放键」这个假设——
    // **实测不成立，已删**。0.4 秒的按住照样被当成短按，停止那一下就唤起音乐 App。
    // 「按住说话」之所以没这个毛病，是因为用户实际按住的是说话那几秒，
    // 而不是因为跨过了 0.35 秒的阈值。这中间没有可用的时间窗口，别再试。

    var title: String {
        switch self {
        case .hold: "按住说话，松开结束"
        case .toggle: "轻点一下开始，再轻点结束"
        }
    }

    /// 菜单里跟在「触发方式：」后面，不能用上面那句长的
    var shortTitle: String {
        switch self {
        case .hold: "按住说话"
        case .toggle: "轻点切换"
        }
    }

    /// 是不是「松开手还继续录」的那一类。这类才需要自动停止、点图标终止这些收尾手段。
    var keepsRecordingAfterRelease: Bool { self != .hold }
}

/// 配置。用 UserDefaults 就够——这里没有需要 SwiftData 的结构化数据，
/// 也就不用趟 default.store 落在 Application Support 根目录那个坑。
@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let triggerKey = "triggerKey"
        static let triggerMode = "triggerMode"
        static let longPressThreshold = "longPressThreshold"
        static let seizeDevice = "seizeDevice"
        static let preemptNowPlaying = "preemptNowPlaying"
        static let singleClickPlayPause = "singleClickPlayPause"
        static let autoSwitchMic = "autoSwitchMicToHeadset"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let voiceInputMethodID = "voiceInputMethodID"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKey = "globalHotKey"
    }

    private init() {
        // triggerKey 存的是编码后的 Data，缺省时由 triggerShortcut 的 getter
        // 回落到 .fnOnly，不在这里注册
        defaults.register(defaults: [
            Key.enabled: true,
            Key.triggerMode: TriggerMode.hold.rawValue,
            Key.preemptNowPlaying: true,
            Key.longPressThreshold: 0.35,
            Key.seizeDevice: true,
            Key.singleClickPlayPause: true,
            // 默认关：擅自改系统音频设置是有副作用的行为，让用户自己开。
            // 不开也会在菜单里提示「耳机插着但麦没走耳机麦」。
            Key.autoSwitchMic: false,
            Key.autoCheckUpdates: true,
        ])
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// 触发键。可以是任意组合，只要和输入法里设的那个一致即可。
    var triggerShortcut: Shortcut {
        get {
            guard let data = defaults.data(forKey: Key.triggerKey),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .fnOnly }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.triggerKey)
        }
    }

    /// 线控中键的触发方式。默认「按住说话」——那是不可能忘记关的那一种。
    var triggerMode: TriggerMode {
        get {
            guard let raw = defaults.string(forKey: Key.triggerMode),
                  let mode = TriggerMode(rawValue: raw)
            else { return .hold }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerMode) }
    }

    /// 按住多久算「长按」（秒）。低于这个值算单击。仅「按住说话」模式用得上。
    var longPressThreshold: TimeInterval {
        get { defaults.double(forKey: Key.longPressThreshold) }
        set { defaults.set(newValue, forKey: Key.longPressThreshold) }
    }

    /// 独占线控设备：按键不再传给系统，长按说话时不会误暂停音乐。
    var seizeDevice: Bool {
        get { defaults.bool(forKey: Key.seizeDevice) }
        set { defaults.set(newValue, forKey: Key.seizeDevice) }
    }

    /// 抢占系统的「正在播放」位置，截下线控的播放命令。
    ///
    /// 默认**开**：轻点切换没有别的保护手段了（「按住片刻」那条路已证伪），
    /// 关掉它这个模式必然被音乐 App 抢焦点、等于不可用。
    /// 不想要它那些副作用的话，该换的是触发方式而不是这个开关。
    var preemptNowPlaying: Bool {
        get { defaults.bool(forKey: Key.preemptNowPlaying) }
        set { defaults.set(newValue, forKey: Key.preemptNowPlaying) }
    }

    /// 独占后，把「单击 = 播放/暂停」合成回去。
    var singleClickPlayPause: Bool {
        get { defaults.bool(forKey: Key.singleClickPlayPause) }
        set { defaults.set(newValue, forKey: Key.singleClickPlayPause) }
    }

    /// 每天自动检查一次更新
    var autoCheckUpdates: Bool {
        get { defaults.bool(forKey: Key.autoCheckUpdates) }
        set { defaults.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    /// 用哪个输入法来做语音输入（`TISInputSourceID`）。
    ///
    /// 空 = 不指定，只对当前输入法发触发键（老行为：当前恰好是语音输入法时才有用）。
    /// 指定了就会在触发时临时借用它，说完还回去——因为输入法非激活时**根本不响应**
    /// 触发键，详见 `InputMethodSwitcher`。
    var voiceInputMethodID: String? {
        get {
            let value = defaults.string(forKey: Key.voiceInputMethodID)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: Key.voiceInputMethodID) }
    }

    /// 启用全局快捷键（键盘上按，不经耳机线控）
    var hotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.hotKeyEnabled) }
        set { defaults.set(newValue, forKey: Key.hotKeyEnabled) }
    }

    /// 用户按的那个全局快捷键。
    ///
    /// 和 `triggerShortcut` 是两回事，别混：这个是**我们监听**的，
    /// `triggerShortcut` 是我们**合成发给输入法**的。两者可以相同（默认都是 fn），
    /// 那种情况下等于「把 fn 从系统手里接管过来，切好输入法再原样发出去」。
    var hotKey: Shortcut {
        get {
            guard let data = defaults.data(forKey: Key.hotKey),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .fnOnly }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.hotKey)
        }
    }

    /// 插入耳机时自动把麦克风输入切到耳机麦。
    /// macOS 大多数时候会自己切，但会记住上次选择、也可能被别的 app 抢走。
    var autoSwitchMicToHeadset: Bool {
        get { defaults.bool(forKey: Key.autoSwitchMic) }
        set { defaults.set(newValue, forKey: Key.autoSwitchMic) }
    }
}
