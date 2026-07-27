import Foundation

/// Thread-safe cancellation shared by the queue and protocol implementations.
/// Handlers are invoked once and may terminate an active subprocess or USB
/// transaction. Registering after cancellation invokes the handler immediately.
nonisolated final class TransferCancellationToken: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: Handler] = [:]

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancellation() throws {
        if isCancellationRequested {
            throw CancellationError()
        }
    }

    @discardableResult
    func register(_ handler: @escaping Handler) -> UUID? {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return nil
        }
        let id = UUID()
        handlers[id] = handler
        lock.unlock()
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()

        callbacks.forEach { $0() }
    }
}

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
                  progress: @escaping (Double) -> Void,
                  cancellation: TransferCancellationToken) async throws
    /// 从 Mac 上传到手机
    func upload(from localURL: URL, to remotePath: String,
                overwrite: Bool,
                progress: @escaping (Double) -> Void,
                cancellation: TransferCancellationToken) async throws
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
