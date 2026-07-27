import Foundation

nonisolated private struct ADBProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

nonisolated private enum ADBProcessExit: Sendable {
    case exited(Int32)
    case timedOut
}

/// Process.terminationHandler can run before or after wait() is installed.
/// This small latch handles both orders and resumes the continuation once.
nonisolated private final class ADBProcessExitLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ADBProcessExit?
    private var continuation: CheckedContinuation<ADBProcessExit, Never>?

    func wait() async -> ADBProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func finish(_ result: ADBProcessExit) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }
}

nonisolated private final class ADBProgressCallbackBox: @unchecked Sendable {
    let callback: (Double) -> Void

    init(_ callback: @escaping (Double) -> Void) {
        self.callback = callback
    }
}

/// Encodes commands sent through `adb shell` and decodes directory records.
/// The record protocol is deliberately independent of `ls` output because
/// Android vendors use different date formats and column layouts.
enum ADBShellProtocol {
    static func quote(_ value: String) -> String {
        // POSIX shells cannot contain a single quote inside a single-quoted
        // string. Close the quote, emit an escaped quote, then reopen it.
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func directoryListingCommand(path: String) -> String {
        """
        directory=\(quote(path))
        if [ ! -d "$directory" ]; then
            printf '%s\\n' 'ADB directory does not exist' >&2
            exit 1
        fi
        if [ ! -r "$directory" ]; then
            printf '%s\\n' 'ADB directory is not readable' >&2
            exit 1
        fi
        for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
            if [ -e "$entry" ] || [ -L "$entry" ]; then
                metadata=$(stat -c '%f %s %Y' -- "$entry") || exit 1
                set -- $metadata
                printf '%s\\000%s\\000%s\\000%s\\000' "$1" "$2" "$3" "${entry##*/}"
            fi
        done
        """
    }

    static func parseDirectoryListing(
        _ output: String,
        parentPath: String
    ) throws -> [RemoteFile] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true {
            fields.removeLast()
        }

        guard fields.count.isMultiple(of: 4) else {
            throw DeviceError.processError("adb 返回了无法识别的目录数据")
        }

        var files: [RemoteFile] = []
        files.reserveCapacity(fields.count / 4)

        for index in stride(from: 0, to: fields.count, by: 4) {
            let modeText = String(fields[index])
            let sizeText = String(fields[index + 1])
            let modifiedText = String(fields[index + 2])
            let name = String(fields[index + 3])

            guard let mode = UInt32(modeText, radix: 16),
                  let size = UInt64(sizeText),
                  let modifiedSeconds = TimeInterval(modifiedText) else {
                throw DeviceError.processError("adb 返回了无效的文件元数据")
            }
            guard name != ".", name != ".." else { continue }

            let fullPath = parentPath.hasSuffix("/")
                ? "\(parentPath)\(name)"
                : "\(parentPath)/\(name)"
            files.append(RemoteFile(
                name: name,
                path: fullPath,
                size: size,
                isDirectory: mode & 0xF000 == 0x4000,
                modifiedDate: Date(timeIntervalSince1970: modifiedSeconds),
                mimeType: nil
            ))
        }

        return files
    }
}

/// Owns one adb child process and drains stdout/stderr concurrently so neither
/// pipe can fill up while a large directory listing or diagnostic is emitted.
nonisolated private final class ADBProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let progressBox: ADBProgressCallbackBox?

    init(executableURL: URL, arguments: [String],
         progress: ((Double) -> Void)? = nil) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        progressBox = progress.map(ADBProgressCallbackBox.init)
    }

    func run(timeout: TimeInterval?,
             cancellation: TransferCancellationToken? = nil) async throws -> ADBProcessResult {
        try cancellation?.checkCancellation()
        let exitLatch = ADBProcessExitLatch()
        process.terminationHandler = { process in
            exitLatch.finish(.exited(process.terminationStatus))
        }

        try process.run()

        let cancellationRegistration = cancellation?.register { [weak self] in
            if self?.process.isRunning == true {
                self?.process.terminate()
            }
        }
        defer { cancellation?.unregister(cancellationRegistration) }

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let outputTask = Task.detached {
            Self.drain(outputHandle)
        }
        let errorTask = Task.detached { [progressBox] in
            Self.drain(errorHandle) { data in
                guard let progressBox,
                      let text = String(data: data, encoding: .utf8) else { return }
                for value in Self.progressValues(in: text) {
                    Task { @MainActor in
                        progressBox.callback(value)
                    }
                }
            }
        }

        var timeoutWorkItem: DispatchWorkItem?
        if let timeout {
            let workItem = DispatchWorkItem { [weak self] in
                guard exitLatch.finish(.timedOut) else { return }
                if self?.process.isRunning == true {
                    self?.process.terminate()
                }
            }
            timeoutWorkItem = workItem
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: workItem
            )
        }

        let exit = await exitLatch.wait()
        timeoutWorkItem?.cancel()

        switch exit {
        case .timedOut:
            throw DeviceError.processError("adb 命令超时（\(Int(timeout ?? 0)) 秒）")
        case .exited(let status):
            let outputData = await outputTask.value
            let errorData = await errorTask.value
            return ADBProcessResult(
                status: status,
                standardOutput: String(data: outputData, encoding: .utf8) ?? "",
                standardError: String(data: errorData, encoding: .utf8) ?? ""
            )
        }
    }

    private static func drain(
        _ handle: FileHandle,
        onChunk: ((Data) -> Void)? = nil
    ) -> Data {
        var collected = Data()
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 16 * 1024),
                      !chunk.isEmpty else { break }
                collected.append(chunk)
                onChunk?(chunk)
            } catch {
                break
            }
        }
        return collected
    }

    private static func progressValues(in text: String) -> [Double] {
        text.components(separatedBy: "%]").compactMap { component in
            guard let bracketIndex = component.lastIndex(of: "[") else { return nil }
            let numberStart = component.index(after: bracketIndex)
            let number = component[numberStart...].trimmingCharacters(in: .whitespaces)
            guard let percent = Double(number) else { return nil }
            return min(max(percent / 100.0, 0), 1)
        }
    }
}

/// ADB 协议实现 — 通过调用 adb 命令行工具与设备通信
final class ADBDevice: DeviceProtocol {
    let name = "ADB Device"
    let protocolType: ProtocolType = .adb
    private(set) var isConnected = false
    
    private var deviceId: String?
    private let adbURL: URL?
    
    init(adbPath: String? = nil) {
        // 优先使用传入路径，否则从 app bundle、SDK 变量、常见路径和 PATH 查找。
        if let adbPath {
            adbURL = ADBDevice.executableURL(at: adbPath)
        } else {
            adbURL = ADBDevice.findADB()
        }
    }
    
    // MARK: - Connection
    
    func connect() async throws {
        // 检测 adb 是否可用
        let version = try await runADB(["version"], timeout: 10)
        guard version.contains("Android Debug Bridge") else {
            throw DeviceError.adbNotFound
        }

        // 显式启动 server，便于把端口占用、权限等启动错误直接反馈给界面。
        _ = try await runADB(["start-server"], timeout: 15)
        
        // 获取已连接设备列表
        let output = try await runADB(["devices"], timeout: 15)
        let lines = output.split(separator: "\n").dropFirst()
        let deviceStates = lines.compactMap { line -> (id: String, state: String)? in
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
        
        guard let firstDevice = deviceStates.first(where: { $0.state == "device" }) else {
            if let blockedDevice = deviceStates.first {
                let hint = blockedDevice.state == "unauthorized"
                    ? "请解锁手机并允许此 Mac 的 USB 调试授权"
                    : "设备状态为 \(blockedDevice.state)，请重新连接后重试"
                throw DeviceError.connectionFailed(hint)
            }
            throw DeviceError.noDeviceFound
        }
        
        deviceId = firstDevice.id
        isConnected = true
    }
    
    func disconnect() async throws {
        deviceId = nil
        isConnected = false
    }
    
    // MARK: - File Operations
    
    func listFiles(at path: String) async throws -> [RemoteFile] {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }

        let command = ADBShellProtocol.directoryListingCommand(path: path)
        let output = try await runADB(["-s", deviceId, "shell", command])
        return try ADBShellProtocol.parseDirectoryListing(output, parentPath: path)
    }
    
    func download(from remotePath: String, to localURL: URL,
                  progress: @escaping (Double) -> Void,
                  cancellation: TransferCancellationToken) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }

        let partialURL = URL(fileURLWithPath:
            localURL.path + ".nextaft-\(UUID().uuidString).part")
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        // adb 自身会在 stderr 输出百分比，无需同步执行 stat 查询文件大小。
        try await runADBWithProgress(
            ["-s", deviceId, "pull", remotePath, partialURL.path],
            progress: progress,
            cancellation: cancellation
        )
        try cancellation.checkCancellation()

        if FileManager.default.fileExists(atPath: localURL.path) {
            _ = try FileManager.default.replaceItemAt(localURL, withItemAt: partialURL)
        } else {
            try FileManager.default.moveItem(at: partialURL, to: localURL)
        }
        committed = true
    }
    
    func upload(from localURL: URL, to remotePath: String,
                overwrite: Bool,
                progress: @escaping (Double) -> Void,
                cancellation: TransferCancellationToken) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }

        let partialPath = remotePath + ".nextaft-\(UUID().uuidString).part"
        do {
            // 先上传到临时名称；只有完整传输后才原子替换目标文件。
            try await runADBWithProgress(
                ["-s", deviceId, "push", localURL.path, partialPath],
                progress: progress,
                cancellation: cancellation
            )
            try cancellation.checkCancellation()
            let commitCommand: String
            if overwrite {
                commitCommand = "mv -f -- \(ADBShellProtocol.quote(partialPath)) "
                    + ADBShellProtocol.quote(remotePath)
            } else {
                let destination = ADBShellProtocol.quote(remotePath)
                commitCommand = "if [ -e \(destination) ] || [ -L \(destination) ]; then "
                    + "printf '%s\\n' 'destination already exists' >&2; exit 1; fi; "
                    + "mv -- \(ADBShellProtocol.quote(partialPath)) \(destination)"
            }
            _ = try await runADB([
                "-s", deviceId, "shell", commitCommand
            ], cancellation: cancellation)
        } catch {
            _ = try? await runADB([
                "-s", deviceId, "shell", "rm -f -- \(ADBShellProtocol.quote(partialPath))"
            ])
            throw error
        }
    }
    
    func deleteFile(at path: String) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }

        let quotedPath = ADBShellProtocol.quote(path)
        let command = "if [ ! -e \(quotedPath) ] && [ ! -L \(quotedPath) ]; then "
            + "printf '%s\\n' 'file does not exist' >&2; exit 1; fi; "
            + "rm -rf -- \(quotedPath)"
        _ = try await runADB(["-s", deviceId, "shell", command])
    }
    
    func createDirectory(at path: String) async throws {
        guard isConnected, let deviceId else { throw DeviceError.notConnected }
        _ = try await runADB([
            "-s", deviceId, "shell", "mkdir -p -- \(ADBShellProtocol.quote(path))"
        ])
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
    
    // MARK: - Process Execution (Non-blocking)
    
    /// 执行 adb 命令（不阻塞主线程）
    @discardableResult
    private func runADB(_ arguments: [String], timeout: TimeInterval? = 30,
                        cancellation: TransferCancellationToken? = nil) async throws -> String {
        guard let adbURL else { throw DeviceError.adbNotFound }
        do {
            try cancellation?.checkCancellation()
            let result = try await ADBProcessRunner(
                executableURL: adbURL,
                arguments: arguments
            ).run(timeout: timeout, cancellation: cancellation)
            try cancellation?.checkCancellation()
            guard result.status == 0 else {
                throw DeviceError.processError(Self.errorMessage(from: result))
            }
            return result.standardOutput
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeviceError {
            throw error
        } catch {
            throw DeviceError.processError(error.localizedDescription)
        }
    }
    
    /// 执行 adb 命令并解析 stderr 中的进度信息（不阻塞主线程）
    private func runADBWithProgress(_ arguments: [String],
                                    progress: @escaping (Double) -> Void,
                                    cancellation: TransferCancellationToken) async throws {
        guard let adbURL else { throw DeviceError.adbNotFound }
        do {
            try cancellation.checkCancellation()
            let result = try await ADBProcessRunner(
                executableURL: adbURL,
                arguments: arguments,
                progress: progress
            ).run(timeout: nil, cancellation: cancellation)
            try cancellation.checkCancellation()
            guard result.status == 0 else {
                throw DeviceError.transferFailed(Self.errorMessage(from: result))
            }
            progress(1.0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DeviceError {
            throw error
        } catch {
            throw DeviceError.processError(error.localizedDescription)
        }
    }

    nonisolated private static func errorMessage(from result: ADBProcessResult) -> String {
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "adb 已退出，状态码：\(result.status)"
    }
    
    // MARK: - ADB 查找
    
    nonisolated static func findADB() -> URL? {
        // 1. App Bundle 内嵌
        let bundledCandidates = [
            Bundle.main.url(forAuxiliaryExecutable: "adb"),
            Bundle.main.url(forResource: "adb", withExtension: nil)
        ].compactMap { $0 }
        if let bundled = bundledCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return bundled.resolvingSymlinksInPath()
        }

        // 2. Android SDK 环境变量和常见路径
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        for variable in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdkRoot = environment[variable], !sdkRoot.isEmpty {
                candidates.append(
                    URL(fileURLWithPath: sdkRoot)
                        .appendingPathComponent("platform-tools/adb").path
                )
            }
        }
        candidates.append(contentsOf: [
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ])

        // 3. Process 不会自行搜索 PATH，因此在这里显式展开每一项目录。
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("adb").path
            })
        }

        for path in candidates {
            if let url = executableURL(at: path) {
                return url
            }
        }
        return nil
    }

    nonisolated private static func executableURL(at path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}
