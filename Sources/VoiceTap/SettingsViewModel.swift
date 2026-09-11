import Combine
import SwiftUI

/// 设置界面的数据源。
///
/// 除了持久化配置，还镜像了三类**不可观察的系统状态**：开机启动、权限、音频设备。
/// 这些东西 SwiftUI 感知不到变化，直接在 View 里现读会让控件状态在重渲染间隙
/// 漂移（显示的值和实际的对不上）。规则：镜像到 `@Published` 作唯一事实源，
/// 操作后回读真实值写回，窗口显示 / app 激活时刷新。
@MainActor
final class SettingsViewModel: ObservableObject {

    /// 触发键或触发方式变更 —— 需要先把当前按着的键释放掉
    var onTriggerChanged: ((String) -> Void)?
    /// 需要重启 HID 监听的变更
    var onMonitorSettingChanged: (() -> Void)?
    /// 自动切麦开关刚打开，立即应用一次
    var onAutoMicEnabled: (() -> Void)?
    /// 「抢占正在播放」开关变了，要跟着注册/注销
    var onNowPlayingSettingChanged: (() -> Void)?
    /// 全局快捷键的开关或键位变了，要重新挂 / 撤掉 EventTap
    var onHotKeySettingChanged: (() -> Void)?
    var onCheckUpdates: (() -> Void)?

    // MARK: 持久化配置

    @Published var enabled: Bool {
        didSet {
            Settings.shared.enabled = enabled
            onMonitorSettingChanged?()
        }
    }

    @Published var triggerShortcut: Shortcut {
        didSet {
            onTriggerChanged?("切换触发键")
            Settings.shared.triggerShortcut = triggerShortcut
        }
    }

    /// 换模式时正按着的键必须先释放：切换模式靠「再按一下」收尾，
    /// 换成按住说话后那一下永远不会到来，触发键就永久卡在按下状态。
    ///
    /// 这里的写入顺序和 `triggerShortcut` **相反**，别照抄那边：
    /// 换触发方式不改触发键，`forceRelease` 用的还是同一个键，没有「必须用旧值释放」
    /// 的问题；而下面的 `onHotKeySettingChanged` 要按**新**模式决定建哪一种 tap，
    /// 先回调后写等于让它读到旧值，建出来的 tap 和当前模式对不上。
    ///
    /// 踩过的那次是抢占开关（当时它还跟着触发方式走）：顺序写反后判断整个反过来，
    /// 切去按住模式反而保持抢占、切回轻点反倒关掉，「轻点又唤起音乐 App」时隐时现。
    /// 抢占现在不看模式了，但那个指纹照旧——**切换某个设置后，另一个联动行为反向**。
    @Published var triggerMode: TriggerMode {
        didSet {
            Settings.shared.triggerMode = triggerMode
            onTriggerChanged?("切换触发方式")
            // 两种模式的 tap 类型不同（listenOnly / defaultTap），必须重建。
            // 放在写配置之后：回调要按**新**模式决定建哪一种
            onHotKeySettingChanged?()
        }
    }

    /// 用哪个输入法做语音输入（`TISInputSourceID`，空串 = 不指定）。
    ///
    /// 写入顺序同 `triggerShortcut`：**先回调后写配置**。回调要用**旧**目标把
    /// 可能正借着的输入法还回去，先写配置的话就变成拿新目标去还，
    /// 用户原来的输入法再也回不来了。
    @Published var voiceInputMethodID: String {
        didSet {
            onTriggerChanged?("切换语音输入法")
            Settings.shared.voiceInputMethodID = voiceInputMethodID.isEmpty ? nil : voiceInputMethodID
        }
    }

    @Published var hotKeyEnabled: Bool {
        didSet {
            onTriggerChanged?("切换全局快捷键开关")
            Settings.shared.hotKeyEnabled = hotKeyEnabled
            onHotKeySettingChanged?()
        }
    }

    /// 用户按的全局快捷键。注意和 `triggerShortcut` 的分工：这个是**监听**的，
    /// 那个是**合成发给输入法**的。
    @Published var hotKey: Shortcut {
        didSet {
            // 先收尾：换了键之后旧键的「松开」永远不会再来，正按着的会卡住
            onTriggerChanged?("切换全局快捷键")
            Settings.shared.hotKey = hotKey
            onHotKeySettingChanged?()
        }
    }

    @Published var longPressThreshold: Double {
        didSet { Settings.shared.longPressThreshold = longPressThreshold }
    }

    @Published var seizeDevice: Bool {
        didSet {
            Settings.shared.seizeDevice = seizeDevice
            onMonitorSettingChanged?()
        }
    }

    @Published var singleClickPlayPause: Bool {
        didSet { Settings.shared.singleClickPlayPause = singleClickPlayPause }
    }

    @Published var preemptNowPlaying: Bool {
        didSet {
            Settings.shared.preemptNowPlaying = preemptNowPlaying
            onNowPlayingSettingChanged?()
        }
    }

    @Published var autoSwitchMic: Bool {
        didSet {
            Settings.shared.autoSwitchMicToHeadset = autoSwitchMic
            if autoSwitchMic { onAutoMicEnabled?() }
        }
    }

    @Published var autoCheckUpdates: Bool {
        didSet { Settings.shared.autoCheckUpdates = autoCheckUpdates }
    }

    // MARK: 系统状态镜像

    @Published private(set) var launchState: LaunchAtLogin.State
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var currentInputUID: String = ""
    /// 有耳机麦在场。只服务于下面的 `micMismatched`，所以判据是「存在耳机的输入设备」，
    /// 比状态栏那个「耳机在场」窄一档——没有麦克风的耳机在这里不算，
    /// 那种情况下也谈不上「录音走没走耳机麦」。
    @Published private(set) var headsetPluggedIn = false
    @Published private(set) var inputMonitoring: Permissions.State = .unknown
    @Published private(set) var accessibility: Permissions.State = .unknown

    /// 本机装了哪些有语音能力的输入法。
    /// 这同样是**外部状态**——用户随时可能在系统设置里增删输入法，
    /// 在 View 里现读会让 Picker 的选项和实际的对不上，所以镜像到这里。
    @Published private(set) var voiceInputMethods: [VoiceInputMethod] = []

    /// 选中的那个输入法已经不在了（被用户从系统设置里移除 / 卸载）。
    /// 不提示的话表现是「按了没反应」，且毫无线索。
    var selectedInputMethodMissing: Bool {
        !voiceInputMethodID.isEmpty && !voiceInputMethods.contains { $0.id == voiceInputMethodID }
    }

    /// 耳机插着，但录音走的不是耳机麦 —— 说的话会被电脑麦收进去，
    /// 用户几乎不可能自己发现
    var micMismatched: Bool {
        guard headsetPluggedIn else { return false }
        guard let current = inputDevices.first(where: { $0.uid == currentInputUID }) else { return false }
        return !current.isHeadsetMic
    }

    var allPermissionsGranted: Bool {
        inputMonitoring == .granted && accessibility == .granted
    }

    init() {
        // init 内的赋值不触发 didSet，所以不会在启动时反向写回一遍
        enabled = Settings.shared.enabled
        triggerShortcut = Settings.shared.triggerShortcut
        triggerMode = Settings.shared.triggerMode
        longPressThreshold = Settings.shared.longPressThreshold
        seizeDevice = Settings.shared.seizeDevice
        singleClickPlayPause = Settings.shared.singleClickPlayPause
        preemptNowPlaying = Settings.shared.preemptNowPlaying
        autoSwitchMic = Settings.shared.autoSwitchMicToHeadset
        autoCheckUpdates = Settings.shared.autoCheckUpdates
        voiceInputMethodID = Settings.shared.voiceInputMethodID ?? ""
        hotKeyEnabled = Settings.shared.hotKeyEnabled
        hotKey = Settings.shared.hotKey
        launchState = LaunchAtLogin.state
        refreshSystemState()
    }

    // MARK: 刷新

    func refreshSystemState() {
        launchState = LaunchAtLogin.state
        inputDevices = AudioDeviceWatcher.inputDevices()
        currentInputUID = AudioDeviceWatcher.currentInputDevice()?.uid ?? ""
        headsetPluggedIn = inputDevices.contains(where: \.isHeadsetMic)
        inputMonitoring = Permissions.inputMonitoring
        accessibility = Permissions.accessibility
        voiceInputMethods = InputMethodCatalog.voiceInputMethods()
    }

    // MARK: 动作

    func setLaunchAtLogin(_ on: Bool) {
        // 用回读到的真实状态覆盖镜像，不假定操作一定成功
        launchState = LaunchAtLogin.set(on)
    }

    func selectInputDevice(uid: String) {
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        if AudioDeviceWatcher.setInputDevice(device) {
            currentInputUID = device.uid
        }
        refreshSystemState()
    }

    func switchToHeadsetMic() {
        guard let mic = inputDevices.first(where: \.isHeadsetMic) else { return }
        selectInputDevice(uid: mic.uid)
    }
}
