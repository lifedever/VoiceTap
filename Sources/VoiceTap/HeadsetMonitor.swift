import Foundation
import IOKit.hid

/// 线控上的按键（HID Consumer Page 0x0C 的 usage）
enum HeadsetButton: UInt32 {
    case playPause = 0xCD
    case volumeUp = 0xE9
    case volumeDown = 0xEA

    var label: String {
        switch self {
        case .playPause: return "中键(播放/暂停)"
        case .volumeUp: return "音量+"
        case .volumeDown: return "音量-"
        }
    }
}

struct HeadsetDeviceInfo {
    let product: String
    let transport: String
    let isSeized: Bool

    /// 这个 HID 节点是不是随耳机拔插而增删的。
    ///
    /// 3.5mm 插孔（transport = Audio）的节点是驱动**常驻**发布的，插不插耳机都在，
    /// 拿它判断「已接入」会永远为真——那条路只能问 Core Audio。
    /// USB 耳机的节点则是真的随插拔出现和消失，它在场就说明耳机在场。
    var isRemovable: Bool { transport != "Audio" }
}

@MainActor
protocol HeadsetMonitorDelegate: AnyObject {
    func headsetButton(_ button: HeadsetButton, pressed: Bool, from product: String)
    func headsetDevicesChanged(_ devices: [HeadsetDeviceInfo])
    /// 设备拔出。必须单独通知：拔出瞬间可能正按着中键，
    /// 那次「松开」永远不会到达，触发键得在这里强制释放。
    func headsetDeviceRemoved(_ product: String)
    func headsetLog(_ message: String)
}

// MARK: - C 回调
//
// 必须是文件级 nonisolated 函数，不能写成闭包字面量。
// Swift 6 会把方法内的闭包推断为 MainActor 隔离，@convention(c) thunk 里
// 会被注入 swift_task_isCurrentExecutorWithFlags 检查；HID 回调在非主线程
// 重入时该检查可能拿到失效的 executor 记录直接 EXC_BAD_ACCESS。
// （PasteMemo v1.7.13 的 Carbon InstallEventHandler 崩溃就是这个成因。）

private func voicetapInputValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let monitor = Unmanaged<HeadsetMonitor>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    guard IOHIDElementGetUsagePage(element) == 0x0C else { return }
    guard let button = HeadsetButton(rawValue: IOHIDElementGetUsage(element)) else { return }

    let pressed = IOHIDValueGetIntegerValue(value) == 1

    // 时间戳必须在这里记，不能等到 delegate 里：MediaKeyBlocker 靠「HID 先到」
    // 这个顺序来区分线控和键盘上的播放键，下面那一跳 main.async 的排队延迟
    // 足以把顺序反过来。
    if button == .playPause, pressed {
        MediaKeySignal.shared.notePlay()
    }

    let device = IOHIDElementGetDevice(element)
    let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"

    monitor.forwardButton(button, pressed: pressed, product: product)
}

private func voicetapDeviceMatchedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HeadsetMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.deviceAppeared(device)
}

private func voicetapDeviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let monitor = Unmanaged<HeadsetMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.deviceDisappeared(device)
}

// MARK: - Monitor

/// 监听耳机线控按键。
///
/// 发现走 IOHIDManager，但**打开是逐设备做的**：只有耳机类设备才 open/seize，
/// 内置键盘绝不碰——否则 seize 会把键盘上的音量键一起吞掉。
final class HeadsetMonitor: @unchecked Sendable {

    weak var delegate: (any HeadsetMonitorDelegate)?

    private var manager: IOHIDManager?
    /// 已接管的设备。key 用 ObjectIdentifier 以免依赖 IOHIDDevice 的 Hashable。
    private var openedDevices: [ObjectIdentifier: (device: IOHIDDevice, info: HeadsetDeviceInfo)] = [:]
    private var seizeDevices = false
    private let lock = NSLock()

    var isRunning: Bool { manager != nil }

    // MARK: 启停

    /// - Parameter seize: 是否独占设备。独占后按键不再传给系统（不会误暂停音乐），
    ///                    单击的播放/暂停由我们自己合成补回。
    func start(seize: Bool) {
        stop()
        seizeDevices = seize

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // 只发现 Consumer Control 设备（线控、键盘媒体键都在这一类）
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x0C,
            kIOHIDDeviceUsageKey as String: 0x01,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, voicetapDeviceMatchedCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, voicetapDeviceRemovedCallback, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // manager 本身用 None 打开：它只负责发现，独占与否由逐设备的 open 决定
        let rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        if rc == kIOReturnSuccess {
            log("HID 监听已启动\(seize ? "（独占模式）" : "")，等待耳机接入")
        } else if rc == kIOReturnNotPermitted {
            log("启动失败：缺少「输入监控」权限，无法读取线控按键")
        } else {
            log("启动失败：0x\(String(UInt32(bitPattern: rc), radix: 16))")
        }
    }

    func stop() {
        guard let mgr = manager else { return }

        lock.lock()
        let devices = openedDevices.values.map(\.device)
        openedDevices.removeAll()
        lock.unlock()

        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        notifyDevices()
    }

    // MARK: 设备接管

    /// 判断一个 Consumer 设备是不是「耳机」。
    ///
    /// 只认 transport，不认 product 名字——`kIOHIDProductKey` 这类显示名在不同
    /// 系统语言下会变，硬编码名字列表迟早在别的语言环境静默失配。
    /// 3.5mm 线控走 Audio；USB-C 耳机走 USB，但 USB 上也有普通键盘，
    /// 所以 USB 设备额外要求它**不是**内置键盘且声明了播放键。
    private func isHeadsetDevice(_ device: IOHIDDevice) -> Bool {
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""

        if transport == "Audio" { return true }

        if transport == "USB" {
            // 内置键盘的 transport 是 FIFO/SPU，走不到这里；但外接键盘会。
            // 用「是否有 Play/Pause 元素」+「不是键盘主用途」再筛一道。
            let usagePairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]
            let isAlsoKeyboard = usagePairs?.contains { pair in
                (pair[kIOHIDDeviceUsagePageKey as String] as? Int) == 0x01
                    && (pair[kIOHIDDeviceUsageKey as String] as? Int) == 0x06
            } ?? false
            return !isAlsoKeyboard
        }

        return false
    }

    fileprivate func deviceAppeared(_ device: IOHIDDevice) {
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "?"

        guard isHeadsetDevice(device) else {
            log("跳过非耳机设备：\(product) [\(transport)]")
            return
        }

        let options = seizeDevices
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)

        var rc = IOHIDDeviceOpen(device, options)
        var seized = seizeDevices

        // 独占失败就降级为共享监听——能用总比不能用好，
        // 代价只是长按时系统也会收到 play/pause。
        if rc != kIOReturnSuccess && seizeDevices {
            log("独占 \(product) 失败(0x\(String(UInt32(bitPattern: rc), radix: 16)))，降级为共享监听")
            rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            seized = false
        }

        guard rc == kIOReturnSuccess else {
            log("打开 \(product) 失败：0x\(String(UInt32(bitPattern: rc), radix: 16))")
            return
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, voicetapInputValueCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let info = HeadsetDeviceInfo(product: product, transport: transport, isSeized: seized)
        lock.lock()
        openedDevices[ObjectIdentifier(device)] = (device, info)
        lock.unlock()

        log("耳机已接入并接管：\(product) [\(transport)]\(seized ? "，独占" : "，共享")")
        notifyDevices()
    }

    fileprivate func deviceDisappeared(_ device: IOHIDDevice) {
        lock.lock()
        let entry = openedDevices.removeValue(forKey: ObjectIdentifier(device))
        lock.unlock()

        guard let entry else { return }
        let product = entry.info.product

        // 设备已经不在了，不必也不该再 IOHIDDeviceClose——句柄随设备移除失效。
        log("耳机已拔出：\(product)")

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.headsetDeviceRemoved(product)
        }
        notifyDevices()
    }

    // MARK: 事件转发

    fileprivate func forwardButton(_ button: HeadsetButton, pressed: Bool, product: String) {
        // HID 回调可能在任意线程，跳回主线程再碰 delegate
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.headsetButton(button, pressed: pressed, from: product)
        }
    }

    private func notifyDevices() {
        lock.lock()
        let infos = openedDevices.values.map(\.info)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.headsetDevicesChanged(infos)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.headsetLog(message)
        }
    }
}
