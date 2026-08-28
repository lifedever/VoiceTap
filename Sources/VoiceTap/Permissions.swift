import ApplicationServices
import Cocoa
import IOKit.hid

/// 这个 app 需要两个 TCC 权限，缺任何一个功能都是残的：
///   - 输入监控 (Input Monitoring)：IOHIDManager 读线控按键
///   - 辅助功能 (Accessibility)：CGEvent 合成按键给输入法
enum Permissions {

    enum State {
        case granted
        case denied
        case unknown

        var label: String {
            switch self {
            case .granted: return "已授权"
            case .denied: return "未授权"
            case .unknown: return "状态未知"
            }
        }
    }

    // MARK: 输入监控

    static var inputMonitoring: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    // MARK: 辅助功能

    static var accessibility: State {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// 弹系统的授权提示。注意：只有进程**没被记录过**时系统才会真的弹窗，
    /// 已经被拒过的只能靠用户去设置里手动开。
    @discardableResult
    static func requestAccessibility() -> Bool {
        // SDK 里 kAXTrustedCheckOptionPrompt 声明成全局 var，Swift 6 判定它
        // 非并发安全而拒绝引用。这个键的字面值是稳定 API 契约，直接写。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: -

    /// 所有权限齐了吗
    static var allGranted: Bool {
        inputMonitoring == .granted && accessibility == .granted
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
