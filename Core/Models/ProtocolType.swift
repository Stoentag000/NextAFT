import Foundation

/// 协议类型
enum ProtocolType: String, CaseIterable, Identifiable {
    case mtp = "MTP"
    case adb = "ADB"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .mtp: return "cable.connector"
        case .adb: return "terminal"
        }
    }
    
    var description: String {
        switch self {
        case .mtp: return "Media Transfer Protocol (直接 USB 传输)"
        case .adb: return "Android Debug Bridge (需开启 USB 调试)"
        }
    }
}
