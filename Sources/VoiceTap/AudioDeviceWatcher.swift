import CoreAudio
import Foundation

/// 一个音频输入设备
struct AudioInputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    /// 是不是「耳机自带的麦克风」。判据由 `AudioDeviceWatcher.isHeadset` 统一给出后
    /// 快照进来——只留一份实现，避免两处各写半套慢慢长歪。
    let isHeadsetMic: Bool
}

/// 判断耳机是否插入。
///
/// 为什么不用 HID：`Product = "Headset"` 那个 HID 节点是插孔驱动**常驻**发布的，
/// 代表「这个口能读线控」，插不插耳机它都在（实测：拔掉耳机后节点数仍为 1）。
/// 所以 IOHIDManager 的 device matching/removal 回调在拔插时根本不触发。
///
/// 真正随耳机增删的是音频设备：3.5mm 插入时系统才创建
/// BuiltInHeadphone{Input,Output}Device，USB 耳机则整个设备随插拔出现和消失。
@MainActor
final class AudioDeviceWatcher {

    /// 内置 3.5mm 插孔耳机的音频设备 UID 前缀。
    /// 这是 Apple 的内部标识符（不是 localizedName 那类会跟随系统语言变的显示名），
    /// 跨语言环境稳定。
    private static let builtInHeadphoneUIDPrefix = "BuiltInHeadphone"

    private(set) var isPluggedIn = false
    var onChange: ((Bool) -> Void)?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: 启停

    func start() {
        refresh(notify: false)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // 回调在指定队列（主队列）上来，但仍要显式跳 MainActor 满足并发检查
            Task { @MainActor in
                self?.refresh(notify: true)
            }
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    func stop() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
    }

    /// 强制重新检测一次。
    ///
    /// listener 不能当成百分百可靠：USB 设备刚出现时声道配置可能还没就绪，
    /// 那一拍会误判成「不是耳机」，而设备列表不会再变第二次——状态就永久卡住了。
    /// 所以除了监听，还要定期对一次账。只在结果真的变了时才通知，重复调用无副作用。
    func recheck() {
        refresh(notify: true)
    }

    // MARK: 检测

    private func refresh(notify: Bool) {
        let plugged = Self.detectHeadphones()
        guard plugged != isPluggedIn else { return }
        isPluggedIn = plugged
        if notify { onChange?(plugged) }
    }

    /// 系统里有没有耳机类音频设备
    private static func detectHeadphones() -> Bool {
        allDeviceIDs().contains(where: isHeadset)
    }

    /// 一个音频设备是不是「耳机」。两条规则，都只用官方 API，不解析任何字符串：
    ///
    /// 1. **内置 3.5mm** —— UID 前缀 `BuiltInHeadphone`。这两个设备（输入、输出各一个）
    ///    只有插了耳机系统才创建，是 3.5mm 唯一可靠的插拔信号。
    /// 2. **USB 耳机** —— transport 是 USB，且**同时具备输入与输出声道**。
    ///    USB 麦克风只有输入、USB 音箱和纯解码 DAC 只有输出，两者兼备的基本
    ///    只有戴在头上的那一类（USB-C 耳机、DAC 耳机、USB 头戴耳麦）。
    ///
    /// 为什么不看设备名：那是 USB 字符串描述符，各家写法五花八门
    /// （"lifeme DAC Headphone" / "USB Audio Device" / "耳机"…），
    /// 硬编码名字列表迟早失配，且是静默失配。
    ///
    /// 蓝牙耳机不算：它没有 HID 线控通道，VoiceTap 对它无能为力，
    /// 报「已接入」只会让人以为该能用了。
    static func isHeadset(_ deviceID: AudioObjectID) -> Bool {
        if let uid = deviceUID(deviceID), uid.hasPrefix(builtInHeadphoneUIDPrefix) { return true }

        guard transportType(deviceID) == kAudioDeviceTransportTypeUSB else { return false }
        return hasChannels(deviceID, scope: kAudioObjectPropertyScopeInput)
            && hasChannels(deviceID, scope: kAudioObjectPropertyScopeOutput)
    }

    /// 内置 3.5mm 插孔里有没有插东西。
    /// 用来判断那个**常驻**的 HID 节点（transport = Audio）此刻是否真的挂着线控。
    static func builtInJackOccupied() -> Bool {
        allDeviceIDs().contains { deviceUID($0)?.hasPrefix(builtInHeadphoneUIDPrefix) == true }
    }

    /// 系统里所有音频设备的 ID
    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr
        else { return [] }

        return ids
    }

    // MARK: 麦克风输入源
    //
    // macOS 插入耳机时**通常**会把输入切到耳机麦，但并不总是可靠
    // （系统会记住上次选择，某些 app 也会自己抢设备）。
    // 所以这里既要能查、也要能切，还要能提示用户「耳机插着但麦没走耳机」。

    /// 所有可用的输入设备（有输入声道的）
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasChannels(id, scope: kAudioObjectPropertyScopeInput),
                  let uid = deviceUID(id),
                  let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, isHeadsetMic: isHeadset(id))
        }
    }

    /// 当前默认输入设备
    static func currentInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
        else { return nil }

        guard let uid = deviceUID(deviceID), let name = deviceName(deviceID) else { return nil }
        return AudioInputDevice(id: deviceID, uid: uid, name: name,
                                isHeadsetMic: isHeadset(deviceID))
    }

    /// 切换默认输入设备
    @discardableResult
    static func setInputDevice(_ device: AudioInputDevice) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &deviceID)
        return status == noErr
    }

    /// 耳机麦（如果耳机插着）
    static func headsetInputDevice() -> AudioInputDevice? {
        inputDevices().first(where: \.isHeadsetMic)
    }

    /// 指定方向上有没有声道。`scope` 传 `kAudioObjectPropertyScopeInput` / `...Output`。
    private static func hasChannels(_ deviceID: AudioObjectID,
                                    scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// 设备的传输方式（`bltn` / `usb ` / `blth` / `hdmi`…）。
    /// 是官方的四字符常量，不随系统语言变，可以安全用来分支。
    private static func transportType(_ deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func deviceName(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return name as String?
    }

    private static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?

        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }
}
