import Foundation

/// App 元信息与外部链接，集中一处。
enum AppInfo {

    static let name = "VoiceTap"

    /// 一句话定位，从能力而非操作步骤切入。
    static let summary = "随手一按，就用你惯用的语音输入法说话"

    /// 副说明。跨输入法调用和麦克风管理都归这个 app，不写出来用户不会知道。
    static let detail = "按耳机线控或键盘快捷键说话，不必手动切换输入法"

    static let repo = "lifedever/VoiceTap"

    /// 版本号只认 Info.plist 这一个源。
    /// 不在代码里另写一份常量——两个源迟早漂移，出现「界面显示 A、更新检查说 B」
    /// 这种自相矛盾，而矛盾本身就是双源的指纹。
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static let homepage = URL(string: "https://www.lifedever.com")

    static let repository = URL(string: "https://github.com/lifedever/VoiceTap")

    static let donate = URL(string: "https://www.lifedever.com")

    static let copyright = "© 2026 lifedever · MIT License"
}
