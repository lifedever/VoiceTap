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

    /// 触发键变更 —— 需要先把旧键释放掉
    var onTriggerChanged: (() -> Void)?
    /// 需要重启 HID 监听的变更
    var onMonitorSettingChanged: (() -> Void)?
    /// 自动切麦开关刚打开，立即应用一次
    var onAutoMicEnabled: (() -> Void)?
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
            onTriggerChanged?()
            Settings.shared.triggerShortcut = triggerShortcut
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
        longPressThreshold = Settings.shared.longPressThreshold
        seizeDevice = Settings.shared.seizeDevice
        singleClickPlayPause = Settings.shared.singleClickPlayPause
        autoSwitchMic = Settings.shared.autoSwitchMicToHeadset
        autoCheckUpdates = Settings.shared.autoCheckUpdates
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
