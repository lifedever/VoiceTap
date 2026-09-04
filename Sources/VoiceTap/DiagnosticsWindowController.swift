import Cocoa
import OSLog

/// 事件监视器：实时显示抓到的线控事件和内部动作。
///
/// 这个窗口不是可有可无的装饰——排查「按了没反应」时，
/// 能一眼分清是「没抓到按键」还是「抓到了但合成没生效」，
/// 比反复改代码猜快一个量级。
///
/// 同一份日志同时进 os_log，于是可以在窗口之外读到：
///
///     log show --last 5m --predicate 'subsystem == "com.lifedever.VoiceTap"'
///
/// 排查线控这类问题必须能和 `rcd` / `mediaremoted` 的系统日志按时间轴对齐，
/// 只存在窗口的内存缓冲里就做不到这件事。
@MainActor
final class DiagnosticsWindowController {

    private static let logger = Logger(subsystem: "com.lifedever.VoiceTap", category: "events")

    /// 暴露给 AppDelegate 判断「是否还有窗口开着」，用于切换 Dock 图标显示
    private(set) var window: NSWindow?
    private var textView: NSTextView?

    private var buffer: [String] = []
    private static let maxLines = 500

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(_ message: String) {
        // 公开可见：这些是设备名和内部动作，不含用户内容
        Self.logger.notice("\(message, privacy: .public)")

        let line = "[\(formatter.string(from: Date()))] \(message)"
        buffer.append(line)
        if buffer.count > Self.maxLines {
            buffer.removeFirst(buffer.count - Self.maxLines)
        }
        render()
    }

    func show() {
        if window == nil { buildWindow() }
        render()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 620, height: 420)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VoiceTap 事件监视器"
        win.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: contentRect)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: contentRect)
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 8, height: 8)

        scrollView.documentView = tv
        win.contentView = scrollView

        // 先定内容尺寸再居中——反过来的话窗口会以近零尺寸居中，
        // 内容到位后向右下展开，最后落在屏幕右下角
        win.setContentSize(contentRect.size)
        win.center()

        window = win
        textView = tv
    }

    private func render() {
        guard let tv = textView else { return }
        tv.string = buffer.joined(separator: "\n")
        tv.scrollToEndOfDocument(nil)
    }
}
