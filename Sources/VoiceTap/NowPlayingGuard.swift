import Cocoa
import MediaPlayer

/// 线控播放键最近一次到达 HID 层的时间。
///
/// HID 回调在任意线程写，命令 handler 在主线程读，所以要加锁。
/// 用 `systemUptime` 而不是 `Date`：它是单调的，不会被系统对时拨走。
final class MediaKeySignal: @unchecked Sendable {
    static let shared = MediaKeySignal()

    private let lock = NSLock()
    private var lastPlayAt: TimeInterval = -.greatestFiniteMagnitude

    func notePlay() {
        lock.lock()
        lastPlayAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func sawPlayRecently(within window: TimeInterval) -> Bool {
        lock.lock()
        let last = lastPlayAt
        lock.unlock()
        return ProcessInfo.processInfo.systemUptime - last < window
    }
}

/// 抢占系统的「正在播放」位置，把线控的播放命令截在自己手里。
///
/// **为什么非得走这条路**（三条更轻的路都已被证伪）：
///
/// | 拦截点 | 为什么不行 |
/// |---|---|
/// | `IOHIDDeviceOpen(seize)` | 独占的是用户态 IOHIDDevice。日志实测「独占」成功，`rcd` 照样收得到 |
/// | `.cghidEventTap` 吞 systemDefined | `rcd` 直接从 HID 层读，经 XPC 发给 `mediaremoted`，根本不进 CG 事件流 |
/// | 合成一个假的目标 | 没有公开 API 能指定命令派发给谁 |
///
/// 实测链路（`log show --predicate 'process == "rcd"'`）：
/// ```
/// 线控中键 --HID--> rcd --XPC(TogglePlayPause)--> mediaremoted
///   --resolvePlayerPath--> com.apple.Music --launchservices--> 启动并抢焦点
/// ```
/// 唯一的介入点是 `resolvePlayerPath` 那一步：注册成 Now Playing App，
/// 命令就会解析到我们身上，Music 不再被启动。
///
/// **代价**：控制中心会显示 VoiceTap 在播放；键盘上的播放键在占着期间失效
/// （命令同样只发到我们这儿，见 `handleCommand`）。所以只在真正需要的窗口里占：
/// 由 `AppDelegate.refreshNowPlayingGuard` 决定启停，条件是轻点切换模式、
/// 开关打开（`Settings.preemptNowPlaying`，默认开——这个模式没有别的保护手段）、
/// **有线耳机在场、权限齐备**。没耳机就不会有线控短按；没「输入监控」就收不到
/// HID 事件，时间窗永远不满足，占着纯属白占。耳机插拔、权限变化都会重新评估。
///
/// 「按住片刻切换」曾被当成零副作用的替代路线，**实测证伪已删**，见 `TriggerMode`。
@MainActor
final class NowPlayingGuard {

    /// HID 与命令派发两路之间允许的间隔。
    ///
    /// 顺序有保证（HID 回调在 IOHIDFamily 用户态客户端层，命令要绕一圈 XPC 才到），
    /// 但**延迟比直觉大得多**：实测 rcd 那一路要 610~810ms 才走完
    /// （`log show --predicate 'process == "rcd"'` 里 Request 到 Response 的间隔）。
    /// 早先定的 0.6 秒每次都差一点没命中，判据形同虚设。这里留足余量——
    /// 反正人在说话时不会顺手去按键盘上的播放键。
    private static let correlationWindow: TimeInterval = 2.0

    var onLog: ((String) -> Void)?

    private var tokens: [(MPRemoteCommand, Any)] = []

    var isRunning: Bool { !tokens.isEmpty }

    func start() {
        guard !isRunning else { return }

        let center = MPRemoteCommandCenter.shared()
        // 只接播放相关的三个。其余（下一曲、快进…）保持不动——
        // 接得越多，键盘和其他遥控设备被误伤的面越大。
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            let token = command.addTarget { [weak self] _ in
                self?.handleCommand() ?? .commandFailed
            }
            tokens.append((command, token))
        }

        // 不声明成 playing，系统不会认我们是 Now Playing App，命令也就不会派发过来
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: AppInfo.name,
            MPMediaItemPropertyArtist: "语音输入待命中",
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing

        onLog?("已抢占「正在播放」位置，线控播放键不再唤起音乐 App")
    }

    func stop() {
        guard isRunning else { return }

        for (command, token) in tokens { command.removeTarget(token) }
        tokens.removeAll()

        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        onLog?("已交还「正在播放」位置")
    }

    /// 线控来的就吃掉，其他来源返回失败让系统去找下家。
    ///
    /// **但别指望后者能救回键盘上的播放键**：一旦我们是 Now Playing App，
    /// 命令就只发到这儿，返回 `.commandFailed` 时 rcd 只是记一条错误后收工，
    /// 并不会再去找音乐 App。实测两条分支的结果是一样的（都不启动 Music）。
    /// 区分仍然做，是为了两件事：日志上能看出这一发是不是线控来的；
    /// 以及 `.success` 不会在系统日志里刷 `PlayerCommandFailed` 的错误。
    /// 「键盘播放键在抢占期间会失效」是这个方案的固有代价，UI 上要如实说。
    private func handleCommand() -> MPRemoteCommandHandlerStatus {
        guard MediaKeySignal.shared.sawPlayRecently(within: Self.correlationWindow) else {
            onLog?("收到非线控来源的播放命令，未处理")
            return .commandFailed
        }
        onLog?("已截下线控播放命令，未唤起音乐 App")
        return .success
    }
}
