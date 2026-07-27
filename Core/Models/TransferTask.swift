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

/// 同名文件的处理方式。默认由界面选择，并在任务入队时固定下来。
enum TransferConflictPolicy: String, CaseIterable, Identifiable {
    case overwrite
    case skip
    case rename

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overwrite: return "覆盖"
        case .skip: return "跳过"
        case .rename: return "自动重命名"
        }
    }

    var icon: String {
        switch self {
        case .overwrite: return "doc.on.doc"
        case .skip: return "forward.end"
        case .rename: return "pencil"
        }
    }

    var help: String {
        switch self {
        case .overwrite: return "用传输文件替换同名文件"
        case .skip: return "保留已有文件，不创建传输任务"
        case .rename: return "为新文件添加编号以保留两者"
        }
    }
}

enum TransferStatus: Equatable {
    case pending
    case inProgress
    case completed
    case failed(String)
    case cancelled
}
