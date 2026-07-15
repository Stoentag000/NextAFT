import Foundation

/// 传输任务
struct TransferTask: Identifiable {
    let id = UUID()
    let sourcePath: String
    let destinationPath: String
    let fileName: String
    let fileSize: UInt64
    let direction: TransferDirection
    var status: TransferStatus = .pending
    var progress: Double = 0
    var transferredBytes: UInt64 = 0
    let startDate: Date = Date()
    var endDate: Date?
    
    var speed: UInt64 {
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 0 else { return 0 }
        return UInt64(Double(transferredBytes) / elapsed)
    }
    
    var speedDescription: String {
        let bytes = speed
        if bytes > 1_048_576 {
            return String(format: "%.1f MB/s", Double(bytes) / 1_048_576)
        } else if bytes > 1024 {
            return String(format: "%.1f KB/s", Double(bytes) / 1024)
        }
        return "\(bytes) B/s"
    }
}

enum TransferDirection {
    case uploadToPhone    // Mac → Android
    case downloadToMac    // Android → Mac
}

enum TransferStatus: Equatable {
    case pending
    case inProgress
    case completed
    case failed(String)
    case cancelled
}
