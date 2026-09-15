import AppKit
import CoreAudio

/// 临时「借用」某个输入法来做语音输入，用完立刻还回去。
///
/// ## 为什么必须借
///
/// 实测（`CGGetEventTapList` + 麦克风/浮窗观测）：微信输入法装了一个**常驻的
/// HID 层 event tap**，切到任何别的输入法它都不撤，所以按键它**收得到**；
/// 但它自己会检查「我是不是当前输入法」，不是就直接不响应——非激活状态下按
/// 触发键，麦克风不启动、浮窗不出现，零反应。豆包同理。
///
/// 也就是说「不切输入法就调起它的语音」在外部是做不到的。唯一的出路是把输入法
/// 借过来几秒，说完还回去：用户的默认输入法不变，打字习惯不受影响。
///
/// ## 归还和触发键释放是同一个等级的事
///
/// 借了不还 = 用户的输入法被永久改掉，正是这个功能最该避免的后果。所以归还
/// 必须铺满所有出口（见 `AppDelegate` 和 `PTTController` 的调用点），并且有
/// 一条无条件的超时兜底。
///
/// ## 「归还成功」不等于用户的输入法回来了
///
/// 系统设置里的「每个文稿使用不同的输入法」（`TextInputGlobalPropertyPerContextInput`）
/// 默认开着。开着时 `TISSelectInputSource` 不只是改全局当前输入法，还会被系统
/// 记进**当前聚焦那个上下文**的输入法记忆里；而归还同样只改得到归还那一刻
/// 聚焦的那一个。于是只要借用的这几秒里焦点换过 App，被换走的那个 App 就
/// 永久停在借来的输入法上——下次切回去，系统自动把它恢复成豆包。
///
/// 见 `handleAppActivated`：借用期间焦点一变就提前归还（不再污染新的 App），
/// 并记下污染过的 App，等用户回去时把它改回来。
@MainActor
final class InputMethodSwitcher {

    /// 借出去最长多久必须还。兜住所有「收不到结束事件」的异常路径。
    /// 取值和 PTT 的超时保护同量级——那边卡住的是修饰键，这边卡住的是输入法。
    private static let maxBorrowDuration: TimeInterval = 120

    /// 松开键之后，最多等多久麦克风才停。超过就不等了直接还。
    /// 输入法偶尔会因为网络慢而多占一会儿麦克风，不能无限等。
    private static let maxMicWait: TimeInterval = 4.0

    /// 麦克风停止后再等一手才归还。
    ///
    /// 录音停 ≠ 出字完成：识别结果还要经 IMKit 送进目标 App，而那条通道
    /// 依赖「它仍是当前输入法」。还早了字就出不来——且是静默的，用户只看到
    /// 说了话没反应。这段宽限期就是留给出字的。
    private static let restoreGrace: TimeInterval = 0.45

    /// 麦克风本来就被别人占着时的固定归还延迟。
    /// 比 `restoreGrace` 长一些——这时没有任何信号可依，只能给识别留够时间。
    private static let busyMicRestoreDelay: TimeInterval = 1.2

    /// 借用中吗
    private(set) var isBorrowing = false

    /// 借之前用户在用的那个。归还就是切回它。
    private var originalID: String?
    /// 借的是哪个。归还前要核对当前输入法还是不是它——不是就说明用户
    /// 中途自己切走了，那不能覆盖用户的选择。
    private var borrowedID: String?

    private var timeoutTimer: Timer?
    private var micWaitTimer: Timer?
    private var micWaitDeadline: Date?

    /// 借的那一刻麦克风是不是已经被别人占着（会议软件、录音 App…）。
    ///
    /// 是的话「麦克风停止」就不能再当识别结束的信号用——它永远不会停，
    /// 每次都要空等到 `maxMicWait` 超时才归还，而那几秒里用户打字用的
    /// 还是借来的输入法。这种情况下退回固定延迟。
    private var micBusyAtBorrow = false

    /// 焦点刚变时不能立刻判断当前输入法。
    ///
    /// 系统自己的 per-context 恢复也在这一拍——实测前台进程切换到目标输入法
    /// `Activate Server` 只隔 47ms。抢在它前面读 `currentID()` 拿到的是上一个
    /// 上下文的值，据此做的判断全是错的。
    private static let focusSettleDelay: TimeInterval = 0.15

    /// 借用刚开始的这一小段不算「用户切了 App」。
    ///
    /// 借用本身会引起一串连锁反应——目标输入法激活、浮窗弹出、目标 App 重新
    /// 拿回焦点——其中任何一步都可能发出一次激活通知。不留宽限期的话，语音会
    /// 刚开口就被自己的提前归还掐断，而且掐得很安静：切换、发键、日志全都正常，
    /// 只有字出不来。`AppDelegate.autoStopGrace` 栽过同一个跟头，取同一量级。
    private static let focusGrace: TimeInterval = 0.6

    /// 污染补偿的有效期。过了就不再动用户的输入法：隔得太久时，
    /// 「这个 App 里我用的是哪个输入法」已经变成用户自己的选择了。
    private static let repairWindow: TimeInterval = 600

    /// 借用期间聚焦过、因此被系统记成「这个 App 用借来的输入法」的那些 App，
    /// 连同**那一次**借用的「借了谁 / 原本是谁」。
    ///
    /// 必须按 App 分别记，不能只留一份最近的：两次借用的原输入法可能不同
    /// （微信 App 里原本是微信输入法，终端里原本是 ABC），共用一份会在补偿时
    /// 把前一个 App 改成后一次的原值——用户的输入法被换成一个毫不相干的。
    /// 每个 App 只补偿一次，补完就移出去，免得反复覆盖用户后来的选择。
    private var pollutedApps: [String: (borrowed: String, original: String)] = [:]
    private var borrowStartedAt: Date?
    private var repairTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    var onLog: ((String) -> Void)?

    // MARK: 借

    enum BorrowResult {
        /// 本来就是目标输入法，没切，可以立刻发触发键
        case alreadyActive
        /// 真的切过去了，**必须等它就绪**再发触发键
        case switched
        case failed
    }

    /// 切到目标输入法。
    ///
    /// 当前就是目标时不做任何切换，也不记归还目标——这条路径最常见
    /// （用户本来就在用那个输入法），白切一次反而会把正在输入的拼音顶掉。
    @discardableResult
    func borrow(_ targetID: String) -> BorrowResult {
        cancelMicWait()

        let current = InputMethodCatalog.currentID()
        guard current != targetID else {
            log("当前已是目标输入法，无需切换")
            return .alreadyActive
        }

        guard InputMethodCatalog.select(targetID) else {
            log("⚠️ 切换到 \(InputMethodCatalog.displayName(for: targetID) ?? targetID) 失败")
            return .failed
        }

        // 已经借着又来一次（比如上一次还没还完就再次触发）：originalID 保持
        // 最早那次的值，否则会把「借来的输入法」当成用户原本的，永远还不回去
        if !isBorrowing {
            originalID = current
            micBusyAtBorrow = Self.micInUse()
        }
        borrowedID = targetID
        isBorrowing = true

        // 这一次切换已经被系统记进当前 App 的输入法记忆了，先记下来。
        // 归还只改得到归还那一刻聚焦的那个 App，中途换了焦点这个就修不到。
        borrowStartedAt = Date()
        markPolluted(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        startWatchingActivation()

        log("借用 \(InputMethodCatalog.displayName(for: targetID) ?? targetID)（原为 \(current.flatMap(InputMethodCatalog.displayName) ?? "未知")）")

        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.maxBorrowDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restoreNow(reason: "借用超时") }
        }
        return .switched
    }

    /// 切换之后要等多久才能发触发键。
    ///
    /// `TISSelectInputSource` 返回 `noErr` **不等于**输入法已经就绪：它只是把
    /// 请求提交出去，目标输入法进程收到激活、接管输入上下文是异步的。
    /// 在那之前发的触发键会被它当成「我不是当前输入法」而丢掉——而且丢得很安静，
    /// VoiceTap 这边切换成功、按键也合成了，日志全是正常的，只有麦克风不启动。
    ///
    /// 实测（同一台机器，各 4~5 次）：
    ///   - 切完同一毫秒就发 → 0~1 成功
    ///   - 隔 50ms 发       → 全部成功
    ///   - 隔 1.8s 发       → 全部成功
    /// 取 150ms 是在实测下限上留了 3 倍余量。人对「按下到开始录音」的感知阈值
    /// 远大于此，而输入法自己启动录音还要 1.4 秒，这点延迟淹没在里面。
    static let readyDelay: TimeInterval = 0.15

    // MARK: 还

    /// 说完了，等出字结束再还。
    ///
    /// 不立即还是因为录音停止那一刻文字还没送出去。这里以「麦克风不再被占用」
    /// 作为识别结束的信号——比拍脑袋定一个固定延迟准：说得短就还得早，
    /// 说得长也不会提前把通道掐断。
    func scheduleRestore() {
        guard isBorrowing else { return }
        cancelMicWait()

        micWaitDeadline = Date().addingTimeInterval(Self.maxMicWait)
        micWaitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMicThenRestore() }
        }
    }

    private func pollMicThenRestore() {
        guard isBorrowing else { cancelMicWait(); return }

        let expired = micWaitDeadline.map { Date() >= $0 } ?? true

        // 两个条件都要满足才算真的结束：
        //   麦克风放开 —— 录音停了
        //   浮窗消失   —— 字也送出去了
        // 只看麦克风会**早还 0.2~0.7 秒**，而那正是输入法在出字的时间。
        // 切回纯键盘布局（ABC）时它还能勉强写完，切回另一个 IMKit 输入法
        // （豆包→微信输入法）就会被抢走上下文，整段话静默丢掉。
        // 借之前麦克风就被别人占着（会议软件…）时，"放开麦克风"这个信号永远不会来，
        // 那种情况只认浮窗
        let micBusy = micBusyAtBorrow ? false : Self.micInUse()
        let busy = micBusy || borrowedPanelVisible()
        guard !busy || expired else { return }

        cancelMicWait()
        let reason = expired && busy ? "等待超时" : "识别结束"
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreGrace) { [weak self] in
            self?.restoreNow(reason: reason)
        }
    }

    /// 借来的那个输入法还有没有浮窗挂在屏幕上
    private func borrowedPanelVisible() -> Bool {
        guard let id = borrowedID,
              let bundleID = InputMethodCatalog.bundleID(for: id) else { return false }
        return InputMethodCatalog.hasVisibleWindow(bundleID: bundleID)
    }

    /// 立即归还。所有兜底路径（拔耳机、睡眠、关开关、退出）都走这里。
    func restoreNow(reason: String) {
        cancelMicWait()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        borrowStartedAt = nil

        guard isBorrowing, let original = originalID else {
            isBorrowing = false
            borrowedID = nil
            return
        }
        isBorrowing = false
        originalID = nil
        defer { borrowedID = nil }

        // 借用期间用户自己切走了 —— 那是他的选择，不能覆盖
        if let borrowed = borrowedID, InputMethodCatalog.currentID() != borrowed {
            log("归还跳过（\(reason)）：输入法已被切换到别处，保留用户的选择")
            return
        }

        if InputMethodCatalog.select(original) {
            log("归还 \(InputMethodCatalog.displayName(for: original) ?? original)（\(reason)）")
        } else {
            log("⚠️ 归还失败：找不到 \(original)")
        }
    }

    private func cancelMicWait() {
        micWaitTimer?.invalidate()
        micWaitTimer = nil
        micWaitDeadline = nil
    }

    // MARK: 「每个文稿使用不同的输入法」的连带污染
    //
    // 见类型注释。焦点变化要处理两件事，缺一件都留得下残留：
    //
    //   提前归还 —— 借用期间焦点一换 App 就还。再借下去只会把新的那个 App
    //               也记成借来的输入法，而识别结果此刻已经进不到原来那个
    //               输入框里了，多借这几秒没有任何收益。
    //   事后补偿 —— 记下被污染的 App，等用户切回去时如果当时正是借来的那个，
    //               就改回来。这一条救的是提前归还救不到的：焦点都已经离开了，
    //               那时候 select 写进去的是**新** App 的记忆。
    //
    // 两条判断都要等 `focusSettleDelay`：系统自己的 per-context 恢复也在这一拍。

    private func startWatchingActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // 取 userInfo 里那个而不是事后问 frontmostApplication：通知到达时
            // 后者偶尔还没翻页，读到的是切换**前**那个 App。
            // 只把 String 带过隔离边界，NSRunningApplication 过不去。
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let name = app?.localizedName
            Task { @MainActor in self?.handleAppActivated(bundleID: bundleID, name: name) }
        }
    }

    private func stopWatchingActivation() {
        // 借用期间这个监听还兼着「焦点一变就提前归还」，不能拆
        guard !isBorrowing, let observer = activationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        activationObserver = nil
    }

    private func handleAppActivated(bundleID: String?, name: String?) {
        // 没在借用、也没有待补偿的 App 时这里没有任何事可做。
        // 放在最前面：下面那个输入法判断要扫目录，不该每次 ⌘Tab 都做一遍
        guard isBorrowing || !pollutedApps.isEmpty else { return }

        guard let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              !InputMethodCatalog.isInputMethod(bundleID: bundleID) else { return }

        if isBorrowing {
            // 归还慢一拍的话这个 App 也会被记上，一并盯着。
            // 宽限期内也要记——那几百毫秒里的污染是真的，只是不该归还
            markPolluted(bundleID)

            // 刚开口的这一下多半是借用自己的连锁反应，不是用户真的换了地方
            if let started = borrowStartedAt,
               Date().timeIntervalSince(started) < Self.focusGrace { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusSettleDelay) { [weak self] in
                self?.restoreNow(reason: "切换了 App")
            }
            return
        }
        repairIfPolluted(bundleID: bundleID, name: name ?? bundleID)
    }

    /// 记下「这个 App 的输入法记忆刚被我们带偏」，连同当前这次借用的两个 ID。
    private func markPolluted(_ bundleID: String?) {
        guard let bundleID,
              bundleID != Bundle.main.bundleIdentifier,
              let borrowed = borrowedID,
              let original = originalID else { return }
        pollutedApps[bundleID] = (borrowed: borrowed, original: original)

        repairTimer?.invalidate()
        repairTimer = Timer.scheduledTimer(withTimeInterval: Self.repairWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endRepairWindow() }
        }
    }

    private func endRepairWindow() {
        repairTimer?.invalidate()
        repairTimer = nil
        pollutedApps.removeAll()
        stopWatchingActivation()
    }

    /// 切回了一个借用期间被带偏的 App —— 把它的输入法改回去。
    private func repairIfPolluted(bundleID: String, name: String) {
        guard let record = pollutedApps[bundleID] else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusSettleDelay) { [weak self] in
            guard let self, !self.isBorrowing else { return }
            // ⌘Tab 一路划过去的中间站，用户根本没停在这儿：
            // 此刻的当前输入法不是它的，不能拿来判断，也不该消耗掉那一次机会
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            guard self.pollutedApps.removeValue(forKey: bundleID) != nil else { return }
            if self.pollutedApps.isEmpty { self.endRepairWindow() }

            // 已经不是借来的那个了：要么系统压根没记住，要么用户后来自己改过。
            // 两种都不该动——后者动了就是覆盖用户的选择，正是这个功能最该避免的
            guard InputMethodCatalog.currentID() == record.borrowed else { return }
            guard InputMethodCatalog.select(record.original) else {
                self.log("⚠️ 修正 \(name) 的输入法失败：找不到 \(record.original)")
                return
            }
            let from = InputMethodCatalog.displayName(for: record.borrowed) ?? record.borrowed
            let to = InputMethodCatalog.displayName(for: record.original) ?? record.original
            self.log("修正 \(name) 的输入法：\(from) → \(to)（借用时被系统记住了）")
        }
    }

    // MARK: 麦克风占用

    /// 默认输入设备正在被**任何进程**使用。
    ///
    /// 用 `kAudioDevicePropertyDeviceIsRunningSomewhere` 而不是自己开一路录音去探：
    /// 它是只读查询，不碰麦克风、不需要麦克风权限，也不会和输入法抢设备。
    static func micInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }

        var runningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    private func log(_ message: String) { onLog?(message) }
}
