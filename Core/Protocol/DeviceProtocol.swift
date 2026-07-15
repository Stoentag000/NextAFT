import Foundation

/// 设备协议统一接口 — MTP 和 ADB 都实现这个协议
@MainActor
protocol DeviceProtocol: AnyObject {
    /// 协议名称
    var name: String { get }
    /// 协议类型
    var protocolType: ProtocolType { get }
    /// 是否已连接
    var isConnected: Bool { get }
    
    /// 连接设备
    func connect() async throws
    /// 断开连接
    func disconnect() async throws
    /// 列出指定路径下的文件
    func listFiles(at path: String) async throws -> [RemoteFile]
    /// 从手机下载到 Mac
    func download(from remotePath: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws
    /// 从 Mac 上传到手机
    func upload(from localURL: URL, to remotePath: String,
                progress: @escaping (Double) -> Void) async throws
    /// 删除远程文件
    func deleteFile(at path: String) async throws
    /// 创建远程目录
    func createDirectory(at path: String) async throws
    /// 获取设备信息
    func getDeviceInfo() async throws -> DeviceInfo
    /// 获取设备存储根路径
    func getRootPath() -> String
}

/// 默认实现
extension DeviceProtocol {
    func getRootPath() -> String {
        "/storage/emulated/0"
    }
}
