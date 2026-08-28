import CoreAudio
import Foundation

/// 一个音频输入设备
struct AudioInputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String

    /// 是不是 3.5mm 耳机自带的麦克风
    var isHeadsetMic: Bool { uid.hasPrefix("BuiltInHeadphone") }
}

/// 判断 3.5mm 耳机是否插入。
///
/// 为什么不用 HID：`Product = "Headset"` 那个 HID 节点是插孔驱动**常驻**发布的，
/// 代表「这个口能读线控」，插不插耳机它都在（实测：拔掉耳机后节点数仍为 1）。
/// 所以 IOHIDManager 的 device matching/removal 回调在拔插时根本不触发。
///
/// 真正随耳机增删的是音频设备：插入时系统才创建 BuiltInHeadphone{Input,Output}Device。
@MainActor
final class AudioDeviceWatcher {

    /// 3.5mm 耳机音频设备的 UID 前缀。
    /// 这是 Apple 的内部标识符（不是 localizedName 那类会跟随系统语言变的显示名），
    /// 跨语言环境稳定。
    private static let headphoneUIDPrefix = "BuiltInHeadphone"

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

    // MARK: 检测

    private func refresh(notify: Bool) {
        let plugged = Self.detectHeadphones()
        guard plugged != isPluggedIn else { return }
        isPluggedIn = plugged
        if notify { onChange?(plugged) }
    }

    /// 枚举所有音频设备，看有没有 UID 以 BuiltInHeadphone 开头的
    private static func detectHeadphones() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return false }

        for deviceID in deviceIDs {
            guard let uid = deviceUID(deviceID) else { continue }
            if uid.hasPrefix(headphoneUIDPrefix) { return true }
        }
        return false
    }

    // MARK: 麦克风输入源
    //
    // macOS 插入耳机时**通常**会把输入切到耳机麦，但并不总是可靠
    // （系统会记住上次选择，某些 app 也会自己抢设备）。
    // 所以这里既要能查、也要能切，还要能提示用户「耳机插着但麦没走耳机」。

    /// 所有可用的输入设备（有输入声道的）
    static func inputDevices() -> [AudioInputDevice] {
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

        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = deviceUID(id),
                  let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
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
        return AudioInputDevice(id: deviceID, uid: uid, name: name)
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

    private static func hasInputChannels(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
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
