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

nonisolated struct USBDeviceStatus: Sendable, Equatable {
    let isConnected: Bool
    let name: String?
    let vendorID: UInt16?
    let productID: UInt16?
}

@MainActor
final class USBDeviceDetector: ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()

    var isDeviceConnected = false { willSet { objectWillChange.send() } }
    var connectedDeviceName: String? { willSet { objectWillChange.send() } }
    var connectedVendorID: UInt16? { willSet { objectWillChange.send() } }
    var connectedProductID: UInt16? { willSet { objectWillChange.send() } }
    var onStatusChange: ((USBDeviceStatus) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var isMonitoring = false

    /// Android 设备的 Vendor ID 列表（常见厂商）
    nonisolated static let androidVendorIDs: Set<UInt16> = [
        0x18D1, // Google
        0x04E8, // Samsung
        0x2717, // Xiaomi
        0x12D1, // Huawei
        0x0BB4, // HTC
        0x19D2, // ZTE
        0x10A9, // LG
        0x0FCE, // Sony
        0x22B8, // Motorola
        0x0B05, // ASUS
        0x0502, // Acer
        0x0955, // NVIDIA
        0x1949, // Amazon
        0x2A70, // OnePlus
        0x2D95, // OPPO
        0x2A45, // Meizu
        0x0489, // Foxconn (various)
        0x17EF, // Lenovo
        0x0E8D, // MediaTek (many Chinese brands)
        0x2C02, // Realme
        0x2E04, // HMD / Nokia
    ]

    // MARK: - Lifecycle

    func startMonitoring() {
        guard !isMonitoring else {
            refreshDeviceStatus()
            return
        }

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
            stopMonitoring()
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
            stopMonitoring()
            return
        }

        service = IOIteratorNext(removedIterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(removedIterator)
        }

        // Do an initial check
        isMonitoring = true
        refreshDeviceStatus()
        print("[USB] Monitoring started")
    }

    func stopMonitoring() {
        guard isMonitoring || notifyPort != nil else { return }
        isMonitoring = false
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
        connectedVendorID = nil
        connectedProductID = nil
        print("[USB] Monitoring stopped")
    }

    // MARK: - Device Scanning

    /// Scan all USB devices and check if any Android device is connected
    nonisolated func refreshDeviceStatus() {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
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
            let currentService = service
            defer { IOObjectRelease(currentService) }

            // Read vendor ID
            guard let vendorProp = IORegistryEntryCreateCFProperty(
                currentService, "idVendor" as CFString, kCFAllocatorDefault, 0
            ) else {
                service = IOIteratorNext(iterator)
                continue
            }
            let vendorID = vendorProp.takeRetainedValue() as? Int ?? 0

            // Check if this is a known Android vendor
            let vid = UInt16(vendorID)
            if Self.androidVendorIDs.contains(vid) {
                foundDevice = true
                foundVID = vid

                // Read product ID
                if let productProp = IORegistryEntryCreateCFProperty(
                    currentService, "idProduct" as CFString, kCFAllocatorDefault, 0
                ) {
                    foundPID = UInt16(productProp.takeRetainedValue() as? Int ?? 0)
                }

                // Read product name
                if let nameProp = IORegistryEntryCreateCFProperty(
                    currentService, "USB Product Name" as CFString, kCFAllocatorDefault, 0
                ) {
                    foundName = nameProp.takeRetainedValue() as? String
                }

                // Found one — stop scanning (first match wins)
                break
            }

            service = IOIteratorNext(iterator)
        }

        let status = USBDeviceStatus(
            isConnected: foundDevice,
            name: foundName,
            vendorID: foundVID,
            productID: foundPID
        )

        // Update state on main actor
        Task { @MainActor in
            guard self.isMonitoring else { return }
            self.isDeviceConnected = status.isConnected
            self.connectedDeviceName = status.name
            self.connectedVendorID = status.vendorID
            self.connectedProductID = status.productID
            self.onStatusChange?(status)

            if status.isConnected {
                print("[USB] Android device found: \(status.name ?? "unknown") "
                    + "(VID: \(String(format: "0x%04X", status.vendorID ?? 0)), "
                    + "PID: \(String(format: "0x%04X", status.productID ?? 0)))")
            }
        }
    }
}
