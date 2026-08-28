import Foundation
import ServiceManagement

/// 开机自启。
///
/// ⚠️ `SMAppService.mainApp.status` 是**不可观察**的外部状态：SwiftUI 感知不到它
/// 变化，直接拿它做 Toggle 的数据源，开关的视觉状态会在重渲染间隙自由漂移
/// （失焦回来显示过时值、切个 app 又跳回去）。
/// 所以调用方必须把它镜像到自己的 `@Published` 作唯一事实源，
/// 这里只提供「读一次 / 写一次」的原语。
enum LaunchAtLogin {

    enum State {
        case enabled
        /// macOS 13+ 注册后待用户批准：登录项已出现在系统设置里，但尚未生效。
        /// 把它当成「关」会让用户反复点开关却看不到变化。
        case requiresApproval
        case disabled

        var isOn: Bool { self != .disabled }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    /// - Returns: 操作后回读到的真实状态。调用方应当用它覆盖自己的镜像值，
    ///            而不是假定操作一定成功。
    @discardableResult
    static func set(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 失败不抛给上层：回读真实状态本身就说明了结果
        }
        return state
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
