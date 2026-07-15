import Foundation
import Combine
import IOKit.usb

/// USB 设备检测器 — 监听 Android 设备的插拔
@MainActor
final class USBDeviceDetector: ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()
    
    var isDeviceConnected = false { willSet { objectWillChange.send() } }
    var connectedDeviceName: String? { willSet { objectWillChange.send() } }
    
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    
    /// Android 设备的 Vendor ID 列表（常见厂商）
    static let androidVendorIDs: Set<UInt16> = [
        0x18D1, // Google
        0x04E8, // Samsung
        0x2717, // Xiaomi
        0x12D1, // Huawei
        0x0BB4, // HTC
        0x19D2, // ZTE
        0x10A9, // LG
        0x0FCE, // Sony
        0x2A70, // OnePlus
        0x2D95, // OPPO
        0x2A45, // Meizu
    ]
    
    func startMonitoring() {
        // TODO: 使用 IOKit 监听 USB 设备变化
        // 1. IOServiceAddMatchingNotification(kIOFirstMatchNotification, ...)
        // 2. IOServiceAddMatchingNotification(kIOTerminatedNotification, ...)
        // 3. 过滤 Android Vendor ID
        print("USB 监控已启动")
    }
    
    func stopMonitoring() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }
}
