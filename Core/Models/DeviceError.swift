import Foundation

/// 设备相关错误
enum DeviceError: LocalizedError {
    case notConnected
    case noDeviceFound
    case adbNotFound
    case connectionFailed(String)
    case transferFailed(String)
    case processError(String)
    case fileNotFound(String)
    case permissionDenied(String)
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "设备未连接"
        case .noDeviceFound:
            return "未找到已连接的设备，请确认 USB 已连接且已授权"
        case .adbNotFound:
            return "未找到可执行的 adb，请安装 Android SDK Platform Tools，或将 adb 加入 PATH"
        case .connectionFailed(let msg):
            return "连接失败: \(msg)"
        case .transferFailed(let msg):
            return "传输失败: \(msg)"
        case .processError(let msg):
            return "进程错误: \(msg)"
        case .fileNotFound(let path):
            return "文件不存在: \(path)"
        case .permissionDenied(let msg):
            return "权限不足: \(msg)"
        case .unknown(let msg):
            return "未知错误: \(msg)"
        }
    }
}
