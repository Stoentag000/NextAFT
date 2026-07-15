import Foundation

/// 设备信息
struct DeviceInfo: Identifiable {
    let id = UUID()
    let name: String
    let model: String?
    let serialNumber: String?
    let androidVersion: String?
    let storageTotal: UInt64?
    let storageFree: UInt64?
    let protocolType: ProtocolType
    
    var storageDescription: String {
        guard let total = storageTotal, let free = storageFree else { return "未知" }
        let totalGB = Double(total) / 1_073_741_824
        let freeGB = Double(free) / 1_073_741_824
        return String(format: "%.1f GB / %.1f GB", freeGB, totalGB)
    }
}
