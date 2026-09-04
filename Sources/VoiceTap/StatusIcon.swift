import Cocoa

/// 状态栏图标。
///
/// 不直接用裸的 `headphones` —— 系统的音频输出指示、AirPods 电量、以及一堆
/// 音乐/会议类 app 都用同一个符号，混在菜单栏里根本认不出哪个是自己的。
/// 这里合成「耳机 + 右上角 sparkle」作为专属标记：sparkle 是 AI 语音的通用视觉符号，
/// 既做了区分，也表达了功能。
enum StatusIcon {

    private static let canvasSize = NSSize(width: 21, height: 16)

    /// 右上角的小标记
    enum Badge {
        /// 正常态：AI 语音标记
        case sparkle
        /// 异常态：缺权限等。保留耳机主体，只在角上加叹号——
        /// 换成纯粹的警告三角会丢掉「这是哪个 app」的识别性。
        case alert
        case none

        var symbolName: String? {
            switch self {
            case .sparkle: return "sparkle"
            case .alert: return "exclamationmark.circle.fill"
            case .none: return nil
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .alert: return 9
            default: return 8
            }
        }
    }

    /// - Parameters:
    ///   - base: 主体符号名
    ///   - badge: 右上角标记
    ///
    /// 一律 template，跟着菜单栏前景色走，和旁边其他 app 的图标一致。
    /// 不要给某个状态单独染色：菜单栏里只有你一个是彩的，看起来更像是坏了。
    /// （另外 `button.contentTintColor` 那条路也走不通——它只作用于 template 图，
    /// 而 template 图又由菜单栏按自己的规则上色，两头落空，
    /// 结果是代码里写着红色、屏幕上是黑色。）
    static func make(base baseName: String, badge: Badge = .sparkle) -> NSImage? {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: baseName, accessibilityDescription: nil)?
            .withSymbolConfiguration(baseConfig) else { return nil }

        guard let badgeName = badge.symbolName else {
            base.isTemplate = true
            return base
        }

        let badgeConfig = NSImage.SymbolConfiguration(pointSize: badge.pointSize, weight: .semibold)
        let badgeImage = NSImage(systemSymbolName: badgeName, accessibilityDescription: nil)?
            .withSymbolConfiguration(badgeConfig)

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }

            // 主体靠左下，给右上角的 badge 让出位置
            let baseSize = base.size
            let baseRect = NSRect(x: 0,
                                  y: 0,
                                  width: baseSize.width,
                                  height: baseSize.height)
            base.draw(in: baseRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            guard let badgeImage else { return true }
            let badgeSize = badgeImage.size
            let badgeRect = NSRect(x: canvasSize.width - badgeSize.width,
                                   y: canvasSize.height - badgeSize.height,
                                   width: badgeSize.width,
                                   height: badgeSize.height)

            // 在 badge 周围挖一圈透明，否则两个形状糊在一起，
            // 状态栏那个尺寸下会变成一团看不清的墨点
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.2, dy: -1.2)).fill()

            context.compositingOperation = .sourceOver
            badgeImage.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }

        // template 让系统自己处理深色模式、菜单栏高亮反色
        image.isTemplate = true
        return image
    }
}
