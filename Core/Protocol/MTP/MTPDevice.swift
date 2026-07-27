import Foundation

/// Value types returned by the background MTP worker. AFTL pointers never
/// leave the worker's serial queue.
nonisolated private struct MTPFileEntry: Sendable {
    let name: String
    let size: UInt64
    let isDirectory: Bool
}

nonisolated private struct MTPDeviceDetails: Sendable {
    let manufacturer: String
    let model: String
    let serial: String
    let storageTotal: UInt64?
    let storageFree: UInt64?
}

nonisolated private struct MTPBridgeError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// C callbacks cannot capture a Swift closure. This Sendable box is retained
/// by the worker operation for the complete duration of the synchronous C call.
nonisolated private final class MTPTransferCallbackBox: @unchecked Sendable {
    let callback: (Double) -> Void
    let cancellation: TransferCancellationToken

    init(_ callback: @escaping (Double) -> Void,
         cancellation: TransferCancellationToken) {
        self.callback = callback
        self.cancellation = cancellation
    }
}

nonisolated private final class MTPCancellationRequest: @unchecked Sendable {
    let handle: AFTLSessionRef
    let transferID: UInt64

    init(handle: AFTLSessionRef, transferID: UInt64) {
        self.handle = handle
        self.transferID = transferID
    }
}

/// Owns the raw AFTL handle and confines all access to one serial queue.
/// MTP is transaction-based, so running three transfers concurrently against
/// one USB session is unsafe even though the app-level queue supports it.
nonisolated private final class MTPWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.stoentag.NextAFT.mtp-worker",
                                      qos: .userInitiated)
    private let cancellationQueue = DispatchQueue(
        label: "com.stoentag.NextAFT.mtp-cancellation",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let cancellationQueueKey = DispatchSpecificKey<UInt8>()
    private var handle: AFTLSessionRef?
    private var nextTransferID: UInt64 = 1

    init() {
        queue.setSpecific(key: queueKey, value: 1)
        cancellationQueue.setSpecific(key: cancellationQueueKey, value: 1)
    }

    deinit {
        let close = { [self] in
            drainCancellationQueue()
            if let handle {
                aftl_disconnect(handle)
                self.handle = nil
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            close()
        } else {
            queue.sync(execute: close)
        }
    }

    func connect() async throws {
        try await enqueue { [self] in
            if handle != nil {
                return
            }
            guard let newHandle = aftl_connect(), aftl_is_connected(newHandle) else {
                throw bridgeError(fallback: "未找到可用的 MTP 设备")
            }
            handle = newHandle
        }
    }

    func disconnect() async {
        await enqueueWithoutThrowing { [self] in
            drainCancellationQueue()
            if let handle {
                aftl_disconnect(handle)
                self.handle = nil
            }
        }
    }

    func listFiles(at path: String) async throws -> [MTPFileEntry] {
        try await enqueue { [self] in
            let handle = try connectedHandle()
            var fileList = AFTLFileList()
            let result = aftl_list_files(handle, path, &fileList)
            guard result == 0 else {
                throw bridgeError(fallback: "无法读取 MTP 目录：\(path)")
            }
            defer { aftl_free_file_list(&fileList) }

            guard fileList.count > 0 else { return [] }
            guard let items = fileList.items else {
                throw MTPBridgeError(message: "AFTL 返回了无效的文件列表")
            }

            let count = Int(fileList.count)
            return (0..<count).map { index in
                let item = items[index]
                return MTPFileEntry(
                    name: item.name.map { String(cString: $0) } ?? "",
                    size: item.size,
                    isDirectory: item.is_directory
                )
            }
        }
    }

    func download(from remotePath: String, to localPath: String,
                  progress: @escaping (Double) -> Void,
                  cancellation: TransferCancellationToken) async throws {
        let callbackBox = MTPTransferCallbackBox(
            progress,
            cancellation: cancellation
        )
        try await enqueue { [self, callbackBox, cancellation] in
            try cancellation.checkCancellation()
            let handle = try connectedHandle()
            var objectID: UInt32 = 0
            guard aftl_resolve_path(handle, remotePath, &objectID) == 0,
                  objectID != 0 else {
                throw bridgeError(fallback: "MTP 文件不存在：\(remotePath)")
            }

            let transferID = makeTransferID()
            let cancellationRequest = MTPCancellationRequest(
                handle: handle,
                transferID: transferID
            )
            let registration = cancellation.register { [weak self, cancellationRequest] in
                self?.requestCancellation(cancellationRequest)
            }
            defer { cancellation.unregister(registration) }
            try cancellation.checkCancellation()

            let context = Unmanaged.passUnretained(callbackBox).toOpaque()
            let result = aftl_download(handle, objectID, localPath, { value, context in
                guard let context else { return }
                Unmanaged<MTPTransferCallbackBox>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .callback(value)
            }, context, { context in
                guard let context else { return false }
                return Unmanaged<MTPTransferCallbackBox>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .cancellation.isCancellationRequested
            }, context, transferID)
            try cancellation.checkCancellation()
            guard result == 0 else {
                throw bridgeError(fallback: "MTP 下载失败")
            }
        }
    }

    func upload(from localPath: String, to remotePath: String,
                overwrite: Bool,
                progress: @escaping (Double) -> Void,
                cancellation: TransferCancellationToken) async throws {
        let callbackBox = MTPTransferCallbackBox(
            progress,
            cancellation: cancellation
        )
        try await enqueue { [self, callbackBox, cancellation] in
            try cancellation.checkCancellation()
            let handle = try connectedHandle()
            let remoteURL = URL(fileURLWithPath: remotePath)
            let parentPath = remoteURL.deletingLastPathComponent().path
            let remoteName = remoteURL.lastPathComponent

            var parentID: UInt32 = 0
            guard !remoteName.isEmpty,
                  aftl_resolve_path(handle, parentPath, &parentID) == 0 else {
                throw bridgeError(fallback: "MTP 目标目录不存在：\(parentPath)")
            }

            // MTP does not define portable replace-on-upload semantics. Keep
            // the lookup, optional delete and upload on this worker queue so
            // another MTP operation cannot interleave between them.
            var existingObjectID: UInt32 = 0
            let destinationExists = aftl_resolve_path(
                handle,
                remotePath,
                &existingObjectID
            ) == 0 && existingObjectID != 0
            if destinationExists {
                guard overwrite else {
                    throw MTPBridgeError(message: "MTP 目标文件已存在：\(remotePath)")
                }
                guard FileManager.default.isReadableFile(atPath: localPath) else {
                    throw MTPBridgeError(message: "本地文件不可读：\(localPath)")
                }
                guard aftl_delete(handle, existingObjectID) == 0 else {
                    throw bridgeError(fallback: "无法覆盖 MTP 文件：\(remotePath)")
                }
            }

            let transferID = makeTransferID()
            let cancellationRequest = MTPCancellationRequest(
                handle: handle,
                transferID: transferID
            )
            let registration = cancellation.register { [weak self, cancellationRequest] in
                self?.requestCancellation(cancellationRequest)
            }
            defer { cancellation.unregister(registration) }
            try cancellation.checkCancellation()

            let context = Unmanaged.passUnretained(callbackBox).toOpaque()
            var newObjectID: UInt32 = 0
            let result = aftl_upload(handle, localPath, remoteName, parentID, {
                value, context in
                guard let context else { return }
                Unmanaged<MTPTransferCallbackBox>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .callback(value)
            }, context, { context in
                guard let context else { return false }
                return Unmanaged<MTPTransferCallbackBox>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .cancellation.isCancellationRequested
            }, context, transferID, &newObjectID)
            try cancellation.checkCancellation()
            guard result == 0 else {
                throw bridgeError(fallback: "MTP 上传失败")
            }
        }
    }

    func deleteFile(at path: String) async throws {
        try await enqueue { [self] in
            let handle = try connectedHandle()
            var objectID: UInt32 = 0
            guard aftl_resolve_path(handle, path, &objectID) == 0,
                  objectID != 0 else {
                throw bridgeError(fallback: "MTP 文件不存在：\(path)")
            }
            guard aftl_delete(handle, objectID) == 0 else {
                throw bridgeError(fallback: "MTP 删除失败：\(path)")
            }
        }
    }

    func createDirectory(at path: String) async throws {
        try await enqueue { [self] in
            let handle = try connectedHandle()
            let directoryURL = URL(fileURLWithPath: path)
            let parentPath = directoryURL.deletingLastPathComponent().path
            let directoryName = directoryURL.lastPathComponent

            var parentID: UInt32 = 0
            guard !directoryName.isEmpty,
                  aftl_resolve_path(handle, parentPath, &parentID) == 0 else {
                throw bridgeError(fallback: "MTP 父目录不存在：\(parentPath)")
            }

            var newDirectoryID: UInt32 = 0
            guard aftl_mkdir(handle, directoryName, parentID,
                             &newDirectoryID) == 0 else {
                throw bridgeError(fallback: "MTP 创建目录失败：\(path)")
            }
        }
    }

    func deviceDetails() async throws -> MTPDeviceDetails {
        try await enqueue { [self] in
            let handle = try connectedHandle()
            var info = aftl_get_device_info(handle)
            defer { aftl_free_device_info(&info) }

            if let error = currentError(), !error.isEmpty {
                throw MTPBridgeError(message: error)
            }
            return MTPDeviceDetails(
                manufacturer: info.manufacturer.map { String(cString: $0) } ?? "",
                model: info.model.map { String(cString: $0) } ?? "",
                serial: info.serial.map { String(cString: $0) } ?? "",
                storageTotal: info.storage_total == 0 ? nil : info.storage_total,
                storageFree: info.storage_total == 0 ? nil : info.storage_free
            )
        }
    }

    private func connectedHandle() throws -> AFTLSessionRef {
        guard let handle else {
            throw MTPBridgeError(message: "MTP 设备未连接")
        }
        return handle
    }

    private func makeTransferID() -> UInt64 {
        let id = nextTransferID
        nextTransferID &+= 1
        if nextTransferID == 0 {
            nextTransferID = 1
        }
        return id
    }

    private func requestCancellation(_ request: MTPCancellationRequest) {
        cancellationQueue.async {
            _ = aftl_cancel_transfer(request.handle, request.transferID)
        }
    }

    private func drainCancellationQueue() {
        guard DispatchQueue.getSpecific(key: cancellationQueueKey) == nil else { return }
        cancellationQueue.sync {}
    }

    private func bridgeError(fallback: String) -> MTPBridgeError {
        MTPBridgeError(message: currentError().flatMap { $0.isEmpty ? nil : $0 }
                       ?? fallback)
    }

    private func currentError() -> String? {
        guard let pointer = aftl_last_error() else { return nil }
        return String(cString: pointer)
    }

    private func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enqueueWithoutThrowing(
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }
}

/// MTP implementation backed by android-file-transfer-linux.
@MainActor
final class MTPDevice: DeviceProtocol {
    let name = "MTP Device"
    let protocolType: ProtocolType = .mtp
    private(set) var isConnected = false

    private let worker = MTPWorker()

    func connect() async throws {
        guard !isConnected else { return }
        try await worker.connect()
        isConnected = true
    }

    func disconnect() async throws {
        isConnected = false
        await worker.disconnect()
    }

    func listFiles(at path: String) async throws -> [RemoteFile] {
        let entries = try await worker.listFiles(at: path)
        return entries.map { entry in
            let fullPath = path.hasSuffix("/")
                ? "\(path)\(entry.name)"
                : "\(path)/\(entry.name)"
            return RemoteFile(
                name: entry.name,
                path: fullPath,
                size: entry.size,
                isDirectory: entry.isDirectory,
                modifiedDate: nil,
                mimeType: nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func download(from remotePath: String, to localURL: URL,
                  progress: @escaping (Double) -> Void,
                  cancellation: TransferCancellationToken) async throws {
        try await worker.download(from: remotePath, to: localURL.path,
                                  progress: progress,
                                  cancellation: cancellation)
    }

    func upload(from localURL: URL, to remotePath: String,
                overwrite: Bool,
                progress: @escaping (Double) -> Void,
                cancellation: TransferCancellationToken) async throws {
        try await worker.upload(from: localURL.path, to: remotePath,
                                overwrite: overwrite,
                                progress: progress,
                                cancellation: cancellation)
    }

    func deleteFile(at path: String) async throws {
        try await worker.deleteFile(at: path)
    }

    func createDirectory(at path: String) async throws {
        try await worker.createDirectory(at: path)
    }

    func getDeviceInfo() async throws -> DeviceInfo {
        let details = try await worker.deviceDetails()
        let displayName = [details.manufacturer, details.model]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return DeviceInfo(
            name: displayName.isEmpty ? "Android Device" : displayName,
            model: details.model.isEmpty ? nil : details.model,
            serialNumber: details.serial.isEmpty ? nil : details.serial,
            androidVersion: nil,
            storageTotal: details.storageTotal,
            storageFree: details.storageFree,
            protocolType: .mtp
        )
    }

    func getRootPath() -> String {
        "/storage/emulated/0"
    }
}
