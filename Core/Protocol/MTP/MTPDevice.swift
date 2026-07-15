import Foundation

/// Wraps a Swift closure so it can be passed through a C `void *userdata` parameter.
/// C function pointers can't capture context; this box is heap-allocated and passed as an opaque pointer.
final class ProgressCallbackBox: @unchecked Sendable {
    let callback: (Double) -> Void
    init(_ callback: @escaping (Double) -> Void) { self.callback = callback }
}

/// MTP 协议实现 — 通过 AFTL (android-file-transfer-linux) C wrapper 与设备通信
final class MTPDevice: DeviceProtocol {
    let name = "MTP Device"
    let protocolType: ProtocolType = .mtp
    private(set) var isConnected = false

    /// Opaque handle to the C++ session (AFTLSessionRef)
    private var sessionHandle: AFTLSessionRef?

    // MARK: - Connection

    func connect() async throws {
        let handle = aftl_connect()
        guard let handle, aftl_is_connected(handle) else {
            throw DeviceError.noDeviceFound
        }
        sessionHandle = handle
        isConnected = true
    }

    func disconnect() async throws {
        if let handle = sessionHandle {
            aftl_disconnect(handle)
        }
        sessionHandle = nil
        isConnected = false
    }

    // MARK: - File Listing

    func listFiles(at path: String) async throws -> [RemoteFile] {
        guard let handle = sessionHandle else { throw DeviceError.notConnected }

        var fileList = AFTLFileList()
        let rc = aftl_list_files(handle, path, &fileList)
        guard rc == 0 else {
            throw DeviceError.fileNotFound(path)
        }

        defer { aftl_free_file_list(&fileList) }

        var result: [RemoteFile] = []
        result.reserveCapacity(Int(fileList.count))

        for i in 0..<Int(fileList.count) {
            let item = fileList.items[i]
            let name = String(cString: item.name)
            let fullPath = path.hasSuffix("/")
                ? "\(path)\(name)"
                : "\(path)/\(name)"

            result.append(RemoteFile(
                name: name,
                path: fullPath,
                size: item.size,
                isDirectory: item.is_directory,
                modifiedDate: nil,
                mimeType: nil
            ))
        }

        // Sort: directories first, then by name
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return result
    }

    // MARK: - Download

    func download(from remotePath: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws {
        guard let handle = sessionHandle else { throw DeviceError.notConnected }

        // Resolve path → object ID
        var objectId: UInt32 = 0
        let resolveRC = aftl_resolve_path(handle, remotePath, &objectId)
        guard resolveRC == 0, objectId != 0 else {
            throw DeviceError.fileNotFound(remotePath)
        }

        // Download with progress callback
        // C function pointers can't capture context, so we pass the Swift closure
        // through the C `void *userdata` parameter.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)

            // Wrap the Swift progress closure as an opaque pointer
            let progressBox = ProgressCallbackBox(progress)
            let progressPtr = Unmanaged.passRetained(progressBox).toOpaque()

            DispatchQueue.global(qos: .userInitiated).async {
                let rc = aftl_download(handle, objectId, localURL.path, { prog, ud in
                    // Recover the Swift closure from userdata and call it
                    guard let ud else { return }
                    Unmanaged<ProgressCallbackBox>
                        .fromOpaque(ud)
                        .takeUnretainedValue()
                        .callback(prog)
                }, progressPtr)

                // Release the boxed closure
                Unmanaged<ProgressCallbackBox>.fromOpaque(progressPtr).release()

                if rc == 0 {
                    box.resume(returning: ())
                } else {
                    box.resume(throwing: DeviceError.transferFailed(
                        "MTP download failed with code \(rc)"))
                }
            }
        }
    }

    // MARK: - Upload

    func upload(from localURL: URL, to remotePath: String,
                progress: @escaping (Double) -> Void) async throws {
        guard let handle = sessionHandle else { throw DeviceError.notConnected }

        // Resolve parent directory path → object ID
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        var parentId: UInt32 = 0
        let resolveRC = aftl_resolve_path(handle, parentPath, &parentId)
        guard resolveRC == 0 else {
            throw DeviceError.fileNotFound(parentPath)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)

            let progressBox = ProgressCallbackBox(progress)
            let progressPtr = Unmanaged.passRetained(progressBox).toOpaque()

            DispatchQueue.global(qos: .userInitiated).async {
                var newObjectId: UInt32 = 0
                let rc = aftl_upload(handle, localURL.path, parentId, { prog, ud in
                    guard let ud else { return }
                    Unmanaged<ProgressCallbackBox>
                        .fromOpaque(ud)
                        .takeUnretainedValue()
                        .callback(prog)
                }, progressPtr, &newObjectId)

                Unmanaged<ProgressCallbackBox>.fromOpaque(progressPtr).release()

                if rc == 0 {
                    box.resume(returning: ())
                } else {
                    box.resume(throwing: DeviceError.transferFailed(
                        "MTP upload failed with code \(rc)"))
                }
            }
        }
    }

    // MARK: - Delete

    func deleteFile(at path: String) async throws {
        guard let handle = sessionHandle else { throw DeviceError.notConnected }

        var objectId: UInt32 = 0
        let rc = aftl_resolve_path(handle, path, &objectId)
        guard rc == 0, objectId != 0 else {
            throw DeviceError.fileNotFound(path)
        }

        let delRC = aftl_delete(handle, objectId)
        guard delRC == 0 else {
            throw DeviceError.transferFailed("Delete failed with code \(delRC)")
        }
    }

    // MARK: - Create Directory

    func createDirectory(at path: String) async throws {
        guard let handle = sessionHandle else { throw DeviceError.notConnected }

        let dirName = (path as NSString).lastPathComponent
        let parentPath = (path as NSString).deletingLastPathComponent

        var parentId: UInt32 = 0
        let rc = aftl_resolve_path(handle, parentPath, &parentId)
        guard rc == 0 else {
            throw DeviceError.fileNotFound(parentPath)
        }

        var newDirId: UInt32 = 0
        let mkdirRC = aftl_mkdir(handle, dirName, parentId, &newDirId)
        guard mkdirRC == 0 else {
            throw DeviceError.transferFailed("mkdir failed with code \(mkdirRC)")
        }
    }

    // MARK: - Device Info

    func getDeviceInfo() async throws -> DeviceInfo {
        guard let handle = sessionHandle else { throw DeviceError.notConnected }

        var info = aftl_get_device_info(handle)
        defer { aftl_free_device_info(&info) }

        let manufacturer = info.manufacturer.map { String(cString: $0) } ?? ""
        let model = info.model.map { String(cString: $0) } ?? ""
        let serial = info.serial.map { String(cString: $0) } ?? ""
        let displayName = manufacturer.isEmpty ? model : "\(manufacturer) \(model)"

        return DeviceInfo(
            name: displayName.isEmpty ? "Android Device" : displayName,
            model: model.isEmpty ? nil : model,
            serialNumber: serial.isEmpty ? nil : serial,
            androidVersion: nil,
            storageTotal: nil,
            storageFree: nil,
            protocolType: .mtp
        )
    }

    // MARK: - Root Path

    func getRootPath() -> String {
        return "/storage/emulated/0"
    }
}


