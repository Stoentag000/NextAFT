import Foundation
import Combine
import IOKit
import IOKit.usb

/// USB 设备检测器 — 监听 Android 设备的插拔
/// IOKit callback — must be a top-level C-compatible function (not a closure/property).
private func usbDeviceNotificationCallback(
    _ refCon: UnsafeMutableRawPointer?,
    _ iterator: io_iterator_t
) {
    guard let refCon else { return }
    let detector = Unmanaged<USBDeviceDetector>.fromOpaque(refCon).takeUnretainedValue()

    // Drain the iterator — IOKit delivers all matching existing devices
    var service = IOIteratorNext(iterator)
    while service != 0 {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }

    // Check if any Android device is currently connected
    Task { @MainActor in
        detector.refreshDeviceStatus()
    }
}

@MainActor
final class USBDeviceDetector: ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()

    var isDeviceConnected = false { willSet { objectWillChange.send() } }
    var connectedDeviceName: String? { willSet { objectWillChange.send() } }
    var connectedVendorID: UInt16? { willSet { objectWillChange.send() } }
    var connectedProductID: UInt16? { willSet { objectWillChange.send() } }

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
        0x0489, // Foxconn (various)
        0x2717, // Xiaomi (duplicate for safety)
        0x17EF, // Lenovo
        0x0E8D, // MediaTek (many Chinese brands)
        0x2C02, // Realme
    ]

    // MARK: - Lifecycle

    func startMonitoring() {
        // Get a reference to self as raw pointer for the callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else {
            print("[USB] Failed to create notification port")
            return
        }

        // Add the notification port to the current run loop
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // Match USB devices (IOUSBDevice class)
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)

        // Register for "device added" notifications
        let addResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchingDict,
            { (refCon, iter) in usbDeviceNotificationCallback(refCon, iter) },
            selfPtr,
            &addedIterator
        )

        if addResult != kIOReturnSuccess {
            print("[USB] Failed to add matching notification: \(addResult)")
            return
        }

        // Drain the iterator to arm the notification
        var service = IOIteratorNext(addedIterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(addedIterator)
        }

        // Register for "device removed" notifications
        let removeMatching = IOServiceMatching(kIOUSBDeviceClassName)
        let removeResult = IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            removeMatching,
            { (refCon, iter) in usbDeviceNotificationCallback(refCon, iter) },
            selfPtr,
            &removedIterator
        )

        if removeResult != kIOReturnSuccess {
            print("[USB] Failed to add terminated notification: \(removeResult)")
            return
        }

        service = IOIteratorNext(removedIterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(removedIterator)
        }

        // Do an initial check
        refreshDeviceStatus()
        print("[USB] Monitoring started")
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
            let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        isDeviceConnected = false
        connectedDeviceName = nil
        print("[USB] Monitoring stopped")
    }

    // MARK: - Device Scanning

    /// Scan all USB devices and check if any Android device is connected
    nonisolated func refreshDeviceStatus() {
        var matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var foundDevice = false
        var foundName: String?
        var foundVID: UInt16?
        var foundPID: UInt16?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            // Read vendor ID
            guard let vendorProp = IORegistryEntryCreateCFProperty(
                service, "idVendor" as CFString, kCFAllocatorDefault, 0
            ) else {
                service = IOIteratorNext(iterator)
                continue
            }
            let vendorID = vendorProp.takeUnretainedValue() as? Int ?? 0

            // Check if this is a known Android vendor
            let vid = UInt16(vendorID)
            if Self.androidVendorIDs.contains(vid) {
                foundDevice = true
                foundVID = vid

                // Read product ID
                if let productProp = IORegistryEntryCreateCFProperty(
                    service, "idProduct" as CFString, kCFAllocatorDefault, 0
                ) {
                    foundPID = UInt16(productProp.takeUnretainedValue() as? Int ?? 0)
                }

                // Read product name
                if let nameProp = IORegistryEntryCreateCFProperty(
                    service, "USB Product Name" as CFString, kCFAllocatorDefault, 0
                ) {
                    foundName = nameProp.takeUnretainedValue() as? String
                }

                // Found one — stop scanning (first match wins)
                break
            }

            service = IOIteratorNext(iterator)
        }

        // Update state on main actor
        Task { @MainActor in
            self.isDeviceConnected = foundDevice
            self.connectedDeviceName = foundName
            self.connectedVendorID = foundVID
            self.connectedProductID = foundPID

            if foundDevice {
                print("[USB] Android device found: \(foundName ?? "unknown") "
                    + "(VID: \(String(format: "0x%04X", foundVID ?? 0)), "
                    + "PID: \(String(format: "0x%04X", foundPID ?? 0)))")
            }
        }
    }
}
