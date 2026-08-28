import Foundation

/// 配置。用 UserDefaults 就够——这里没有需要 SwiftData 的结构化数据，
/// 也就不用趟 default.store 落在 Application Support 根目录那个坑。
@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "enabled"
        static let triggerKey = "triggerKey"
        static let longPressThreshold = "longPressThreshold"
        static let seizeDevice = "seizeDevice"
        static let singleClickPlayPause = "singleClickPlayPause"
        static let autoSwitchMic = "autoSwitchMicToHeadset"
        static let autoCheckUpdates = "autoCheckUpdates"
    }

    private init() {
        // triggerKey 存的是编码后的 Data，缺省时由 triggerShortcut 的 getter
        // 回落到 .fnOnly，不在这里注册
        defaults.register(defaults: [
            Key.enabled: true,
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

    /// 按住多久算「长按」（秒）。低于这个值算单击。
    var longPressThreshold: TimeInterval {
        get { defaults.double(forKey: Key.longPressThreshold) }
        set { defaults.set(newValue, forKey: Key.longPressThreshold) }
    }

    /// 独占线控设备：按键不再传给系统，长按说话时不会误暂停音乐。
    var seizeDevice: Bool {
        get { defaults.bool(forKey: Key.seizeDevice) }
        set { defaults.set(newValue, forKey: Key.seizeDevice) }
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

    /// 插入耳机时自动把麦克风输入切到耳机麦。
    /// macOS 大多数时候会自己切，但会记住上次选择、也可能被别的 app 抢走。
    var autoSwitchMicToHeadset: Bool {
        get { defaults.bool(forKey: Key.autoSwitchMic) }
        set { defaults.set(newValue, forKey: Key.autoSwitchMic) }
    }
}
