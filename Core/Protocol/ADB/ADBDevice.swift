import Foundation

/// 线程安全的 Continuation 包装器，确保只 resume 一次
private final class ContinuationBox<T, E: Error>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, E>?
    private let lock = NSLock()
    
    init(_ continuation: CheckedContinuation<T, E>) {
        self.continuation = continuation
    }
    
    /// 只有第一次调用会生效，后续调用静默忽略
    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }
    
    func resume(throwing error: E) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// ADB 协议实现 — 通过调用 adb 命令行工具与设备通信
final class ADBDevice: DeviceProtocol {
    let name = "ADB Device"
    let protocolType: ProtocolType = .adb
    private(set) var isConnected = false
    
    private var deviceId: String?
    private let adbPath: String
    
    init(adbPath: String? = nil) {
        // 优先使用传入路径，否则从 app bundle 或 PATH 查找
        self.adbPath = adbPath ?? ADBDevice.findADB()
    }
    
    // MARK: - Connection
    
    func connect() async throws {
        // 检测 adb 是否可用
        let version = try await runADB(["version"])
        guard version.contains("Android Debug Bridge") else {
            throw DeviceError.adbNotFound
        }
        
        // 获取已连接设备列表
        let output = try await runADB(["devices"])
        let lines = output.split(separator: "\n").dropFirst()
        let devices = lines.compactMap { line -> String? in
            let parts = line.split(separator: "\t")
            guard parts.count >= 2, parts[1] == "device" else { return nil }
            return String(parts[0])
        }
        
        guard let firstDevice = devices.first else {
            throw DeviceError.noDeviceFound
        }
        
        deviceId = firstDevice
        isConnected = true
    }
    
    func disconnect() async throws {
        deviceId = nil
        isConnected = false
    }
    
    // MARK: - File Operations
    
    func listFiles(at path: String) async throws -> [RemoteFile] {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        
        // adb shell ls -la <path>
        let output = try await runADB(["-s", deviceId, "shell", "ls -la \(path.shellEscaped)"])
        let lines = output.split(separator: "\n")
        
        return lines.compactMap { line -> RemoteFile? in
            parseLsLine(String(line), parentPath: path)
        }
    }
    
    func download(from remotePath: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        
        // adb pull <remote> <local> — 解析 stderr 中的进度
        try await runADBWithProgress(
            ["-s", deviceId, "pull", remotePath, localURL.path],
            fileSize: fileSizeForProgress(remotePath),
            progress: progress
        )
    }
    
    func upload(from localURL: URL, to remotePath: String,
                progress: @escaping (Double) -> Void) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        
        // adb push <local> <remote> — 解析 stderr 中的进度
        try await runADBWithProgress(
            ["-s", deviceId, "push", localURL.path, remotePath],
            fileSize: fileSize,
            progress: progress
        )
    }
    
    func deleteFile(at path: String) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        
        // 先判断是文件还是目录
        let statOutput = try await runADB(["-s", deviceId, "shell", "stat -c %F \(path.shellEscaped)"])
        let isDir = statOutput.trimmingCharacters(in: .whitespacesAndNewlines).contains("directory")
        
        if isDir {
            _ = try await runADB(["-s", deviceId, "shell", "rm -rf \(path.shellEscaped)"])
        } else {
            _ = try await runADB(["-s", deviceId, "shell", "rm \(path.shellEscaped)"])
        }
    }
    
    func createDirectory(at path: String) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        _ = try await runADB(["-s", deviceId, "shell", "mkdir -p \(path.shellEscaped)"])
    }
    
    func getDeviceInfo() async throws -> DeviceInfo {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        
        let model = try? await runADBShell("ro.product.model")
        let version = try? await runADBShell("ro.build.version.release")
        let totalStorage = try? await getStorageTotal()
        let freeStorage = try? await getStorageFree()
        
        return DeviceInfo(
            name: model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Android Device",
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines),
            serialNumber: deviceId,
            androidVersion: version?.trimmingCharacters(in: .whitespacesAndNewlines),
            storageTotal: totalStorage,
            storageFree: freeStorage,
            protocolType: .adb
        )
    }
    
    // MARK: - ADB Shell Helpers
    
    private func runADBShell(_ prop: String) async throws -> String {
        guard let deviceId else { throw DeviceError.notConnected }
        return try await runADB(["-s", deviceId, "shell", "getprop \(prop)"])
    }
    
    private func getStorageTotal() async throws -> UInt64? {
        guard let deviceId else { return nil }
        let output = try await runADB(["-s", deviceId, "shell", "df /data | tail -1"])
        let parts = output.split(separator: " ").filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return UInt64(parts[1])
    }
    
    private func getStorageFree() async throws -> UInt64? {
        guard let deviceId else { return nil }
        let output = try await runADB(["-s", deviceId, "shell", "df /data | tail -1"])
        let parts = output.split(separator: " ").filter { !$0.isEmpty }
        guard parts.count >= 4 else { return nil }
        return UInt64(parts[3])
    }
    
    /// 获取远程文件大小（用于计算进度百分比）
    private func fileSizeForProgress(_ remotePath: String) -> UInt64 {
        // 尝试通过 adb shell stat 获取文件大小，失败则返回 0
        // 返回 0 时进度回调仍会工作，只是百分比计算会跳过
        guard let deviceId else { return 0 }
        let semaphore = DispatchSemaphore(value: 0)
        var size: UInt64 = 0
        Task {
            if let output = try? await runADB(["-s", deviceId, "shell", "stat -c %s \(remotePath.shellEscaped)"]) {
                size = UInt64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
            semaphore.signal()
        }
        semaphore.wait()
        return size
    }
    
    // MARK: - Process Execution (Non-blocking)
    
    /// 执行 adb 命令（不阻塞主线程）
    @discardableResult
    private func runADB(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            let process = Process()
            let outputPipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            
            process.terminationHandler = { _ in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                if process.terminationStatus == 0 {
                    box.resume(returning: output)
                } else {
                    box.resume(throwing: DeviceError.processError(output))
                }
            }
            
            do {
                try process.run()
            } catch {
                box.resume(throwing: DeviceError.processError(error.localizedDescription))
            }
        }
    }
    
    /// 执行 adb 命令并解析 stderr 中的进度信息（不阻塞主线程）
    private func runADBWithProgress(_ arguments: [String], fileSize: UInt64,
                                     progress: @escaping (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            // 实时读取 stderr 获取进度
            let errorHandle = errorPipe.fileHandleForReading
            errorHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    // adb 进度格式: "[  5%] /path/to/file" 或 "[100%] /path/to/file"
                    let lines = text.components(separatedBy: "\n")
                    for line in lines {
                        if let percentStr = line.components(separatedBy: "%]").first,
                           let bracketIndex = percentStr.lastIndex(of: "["),
                           percentStr[bracketIndex...].count > 1 {
                            let numStr = percentStr[percentStr.index(after: bracketIndex)...]
                                .trimmingCharacters(in: .whitespaces)
                            if let percent = Double(numStr) {
                                Task { @MainActor in
                                    progress(percent / 100.0)
                                }
                            }
                        }
                    }
                }
            }
            
            process.terminationHandler = { _ in
                // 停止读取 stderr
                errorHandle.readabilityHandler = nil
                
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorHandle.readDataToEndOfFile()
                
                if process.terminationStatus == 0 {
                    Task { @MainActor in progress(1.0) }
                    box.resume(returning: ())
                } else {
                    let errorOutput = String(data: errorData, encoding: .utf8)
                        ?? String(data: outputData, encoding: .utf8)
                        ?? "未知错误"
                    box.resume(throwing: DeviceError.transferFailed(errorOutput))
                }
            }
            
            do {
                try process.run()
            } catch {
                box.resume(throwing: DeviceError.processError(error.localizedDescription))
            }
        }
    }
    
    // MARK: - ls -la 解析
    
    private func parseLsLine(_ line: String, parentPath: String) -> RemoteFile? {
        // 跳过 total 行和空行
        guard !line.hasPrefix("total"), !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 7 else { return nil }
        
        // 解析权限字符串（第 0 列）
        let permissions = String(parts[0])
        let firstChar = permissions.prefix(1)
        
        // 必须是合法的权限格式: -, d, l, c, b, p, s
        guard ["-", "d", "l", "c", "b", "p", "s"].contains(firstChar) else { return nil }
        
        let isDir = firstChar == "d"
        
        // 定位日期字段 — 月份是三个字母的英文缩写
        let months: Set<String> = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var dateStartIndex: Int?
        
        for i in 2..<min(parts.count - 2, 8) {
            if months.contains(String(parts[i])) && i + 1 < parts.count {
                // 验证下一个字段是数字（日期）
                let dayStr = String(parts[i + 1])
                if Int(dayStr) != nil {
                    dateStartIndex = i
                    break
                }
            }
        }
        
        guard let dateIdx = dateStartIndex, dateIdx + 3 < parts.count else { return nil }
        
        // 日期格式: month day year_or_time → 文件名从 dateIdx+3 开始
        let nameStartIdx = dateIdx + 3
        guard nameStartIdx < parts.count else { return nil }
        
        let name = parts[nameStartIdx...].joined(separator: " ")
        
        // 跳过 . 和 ..
        guard name != ".", name != ".." else { return nil }
        
        // 解析文件大小（第 4 列，在 link count / owner / group 之后）
        // 有些 Android ls 输出可能有 owner+group 或只有 owner
        // 保守处理：取 dateIdx 之前的字段中最像数字的
        var size: UInt64 = 0
        for i in stride(from: dateIdx - 1, through: 1, by: -1) {
            if let s = UInt64(parts[i]) {
                size = s
                break
            }
        }
        
        let fullPath = parentPath.hasSuffix("/") ? "\(parentPath)\(name)" : "\(parentPath)/\(name)"
        
        return RemoteFile(
            name: name,
            path: fullPath,
            size: size,
            isDirectory: isDir,
            modifiedDate: nil,
            mimeType: nil
        )
    }
    
    // MARK: - ADB 查找
    
    static func findADB() -> String {
        // 1. App Bundle 内嵌
        if let bundlePath = Bundle.main.path(forResource: "adb", ofType: nil) {
            return bundlePath
        }
        // 2. 常见路径
        let commonPaths = [
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ]
        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // 3. 默认期望在 PATH 中
        return "adb"
    }
}

// MARK: - String Extension

private extension String {
    var shellEscaped: String {
        let specialChars = CharacterSet(charactersIn: " \"'\\(){}[]|&;*?<>~!#$")
        if unicodeScalars.contains(where: { specialChars.contains($0) }) {
            let escaped = replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return self
    }
}
