import Foundation
import Combine
import SwiftUI
import AppKit

/// 文件浏览器 ViewModel
@MainActor
final class FileBrowserViewModel: ObservableObject {
    private enum FileLocation: Equatable {
        case local
        case remote
    }

    private struct PendingDeletion {
        let file: RemoteFile
        let location: FileLocation
        let device: DeviceProtocol?
    }

    let objectWillChange = PassthroughSubject<Void, Never>()
    
    // MARK: - Published State
    var localFiles: [RemoteFile] = [] { willSet { objectWillChange.send() } }
    var remoteFiles: [RemoteFile] = [] { willSet { objectWillChange.send() } }
    var localPath: String = "" { willSet { objectWillChange.send() } }
    var remotePath: String = "/storage/emulated/0" { willSet { objectWillChange.send() } }
    var isLoadingLocal = false { willSet { objectWillChange.send() } }
    var isLoadingRemote = false { willSet { objectWillChange.send() } }
    var selectedProtocol: ProtocolType = .adb { willSet { objectWillChange.send() } }
    var errorMessage: String? { willSet { objectWillChange.send() } }
    var showError = false { willSet { objectWillChange.send() } }
    var isConnected = false { willSet { objectWillChange.send() } }
    var isConnecting = false { willSet { objectWillChange.send() } }
    var isUSBDevicePresent = false { willSet { objectWillChange.send() } }
    var usbDeviceName: String? { willSet { objectWillChange.send() } }
    var conflictPolicy: TransferConflictPolicy = .rename {
        willSet { objectWillChange.send() }
    }
    var showDeleteConfirmation = false { willSet { objectWillChange.send() } }
    var showCreateDirectoryPrompt = false { willSet { objectWillChange.send() } }
    var newDirectoryName = "" { willSet { objectWillChange.send() } }
    /// 授权目录的根路径，不能导航到比这更高的目录
    private(set) var localRootPath: String = ""
    var canNavigateUp: Bool {
        !localRootPath.isEmpty
            && normalizedPath(localPath) != normalizedPath(localRootPath)
    }
    private(set) var remoteRootPath = "/storage/emulated/0"
    var canNavigateRemoteUp: Bool {
        isConnected && normalizedPath(remotePath) != normalizedPath(remoteRootPath)
    }
    var deleteConfirmationMessage: String {
        guard let pendingDeletion else { return "确定要删除所选项目吗？" }
        let kind = pendingDeletion.file.isDirectory ? "文件夹" : "文件"
        return "确定要删除\(kind)“\(pendingDeletion.file.name)”吗？此操作无法撤销。"
    }
    var usbStatusDescription: String {
        if isConnecting { return "正在连接 \(usbDeviceName ?? "Android 设备")…" }
        if isUSBDevicePresent { return "已检测到 \(usbDeviceName ?? "Android 设备")" }
        return "请通过 USB 连接 Android 设备并选择协议"
    }

    // MARK: - Selection
    var selectedLocalFiles: Set<UUID> = [] { willSet { objectWillChange.send() } }
    var selectedRemoteFiles: Set<UUID> = [] { willSet { objectWillChange.send() } }
    
    // MARK: - Dependencies
    private var device: DeviceProtocol?
    let transferManager = TransferManager()
    private let usbDetector = USBDeviceDetector()
    private var pendingDeletion: PendingDeletion?
    private var createDirectoryLocation: FileLocation?
    private var createDirectoryDevice: DeviceProtocol?
    private var connectionGeneration: UInt64 = 0
    private var remoteLoadGeneration: UInt64 = 0
    private var localRefreshTask: Task<Void, Never>?
    private var remoteRefreshTask: Task<Void, Never>?
    private var isInitialized = false
    
    // MARK: - Initialization
    
    private static let bookmarkKey = "LocalDirectoryBookmark"
    private var securityScopedURL: URL?

    init() {
        transferManager.onTaskFinished = { [weak self] task, device in
            self?.handleTransferFinished(task, device: device)
        }
        usbDetector.onStatusChange = { [weak self] status in
            self?.handleUSBStatus(status)
        }
    }

    func initialize() {
        guard !isInitialized else { return }
        isInitialized = true
        // 延迟到当前视图更新周期结束后执行，避免 "Publishing changes from within view updates" 警告
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInitialized else { return }
            if self.localPath.isEmpty {
                self.restoreLocalDirectory()
            }
            self.usbDetector.startMonitoring()
        }
    }

    func shutdown() {
        guard isInitialized else { return }
        isInitialized = false
        localRefreshTask?.cancel()
        remoteRefreshTask?.cancel()
        usbDetector.stopMonitoring()
        isUSBDevicePresent = false
        usbDeviceName = nil
        Task { [weak self] in
            await self?.disconnect()
        }
    }

    /// 尝试从 bookmark 恢复上次的目录，失败则弹出选择面板
    private func restoreLocalDirectory() {
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                if url.startAccessingSecurityScopedResource() {
                    securityScopedURL = url
                    localRootPath = url.path
                    localPath = url.path
                    loadLocalFiles()
                    return
                }
            } catch {
                // bookmark 失效，走下面的选择流程
            }
        }
        // 没有保存的 bookmark 或已失效，让用户选
        promptForLocalDirectory()
    }
    
    /// 弹出目录选择面板
    func promptForLocalDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择本地文件夹"
        panel.message = "请选择一个文件夹作为本地文件浏览器的起始目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // 默认打开用户 Home 目录
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        // 保存 security-scoped bookmark
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkKey)
            
            // 停止访问旧的
            securityScopedURL?.stopAccessingSecurityScopedResource()
            
            if url.startAccessingSecurityScopedResource() {
                securityScopedURL = url
            }
        } catch {
            // bookmark 保存失败，仍然可以使用，只是下次需要重新选
        }
        
        localRootPath = url.path
        localPath = url.path
        loadLocalFiles()
    }
    
    // MARK: - Connection
    
    func connect() async {
        guard !isConnected, !isConnecting else { return }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        isConnecting = true

        let candidate: DeviceProtocol
        switch selectedProtocol {
        case .mtp:
            candidate = MTPDevice()
        case .adb:
            candidate = ADBDevice()
        }
        device = candidate

        do {
            try await candidate.connect()
            guard generation == connectionGeneration, device === candidate else {
                try? await candidate.disconnect()
                return
            }

            remoteRootPath = normalizedPath(candidate.getRootPath())
            remotePath = remoteRootPath
            isConnected = true
            isConnecting = false
            await loadRemoteFiles()
        } catch {
            let isCurrentAttempt = generation == connectionGeneration && device === candidate
            try? await candidate.disconnect()
            if isCurrentAttempt {
                device = nil
                isConnected = false
                isConnecting = false
                remoteFiles = []
                presentError(error.localizedDescription)
            }
        }
    }
    
    func disconnect() async {
        connectionGeneration &+= 1
        let connectedDevice = device
        device = nil
        isConnecting = false
        isConnected = false
        remoteLoadGeneration &+= 1
        isLoadingRemote = false
        remoteFiles = []
        selectedRemoteFiles.removeAll()
        if pendingDeletion?.location == .remote {
            pendingDeletion = nil
            showDeleteConfirmation = false
        }
        if createDirectoryLocation == .remote {
            createDirectoryLocation = nil
            createDirectoryDevice = nil
            showCreateDirectoryPrompt = false
            newDirectoryName = ""
        }
        remotePath = remoteRootPath

        if let connectedDevice {
            transferManager.cancelTasks(for: connectedDevice)
            try? await connectedDevice.disconnect()
        }
    }

    private func handleUSBStatus(_ status: USBDeviceStatus) {
        guard isInitialized else { return }
        let wasPresent = isUSBDevicePresent
        isUSBDevicePresent = status.isConnected
        usbDeviceName = status.name

        guard status.isConnected != wasPresent else { return }
        if status.isConnected {
            guard !isConnected, !isConnecting else { return }
            Task { [weak self] in
                await self?.connect()
            }
        } else if isConnected || isConnecting {
            Task { [weak self] in
                guard let self else { return }
                await self.disconnect()
                // Some phones briefly re-enumerate when switching between
                // charging, ADB and MTP modes. If USB came back while the old
                // session was closing, connect to the new interface now.
                if self.isInitialized && self.isUSBDevicePresent {
                    await self.connect()
                }
            }
        }
    }
    
    // MARK: - Local File Operations
    
    func loadLocalFiles() {
        isLoadingLocal = true
        let url = URL(fileURLWithPath: localPath)
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            localFiles = contents.compactMap { url -> RemoteFile? in
                let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                
                return RemoteFile(
                    name: url.lastPathComponent,
                    path: url.path,
                    size: UInt64(resourceValues?.fileSize ?? 0),
                    isDirectory: resourceValues?.isDirectory ?? false,
                    modifiedDate: resourceValues?.contentModificationDate,
                    mimeType: nil
                )
            }
            .sorted { lhs, rhs in
                // 目录优先，然后按名称排序
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            selectedLocalFiles.removeAll()
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            presentError("没有权限访问该目录。请选择其他目录或重新授权。")
            isLoadingLocal = false
        } catch {
            presentError(error.localizedDescription)
            isLoadingLocal = false
        }
        
        isLoadingLocal = false
    }
    
    func navigateLocal(to file: RemoteFile) {
        guard file.isDirectory,
              isPath(file.path, inside: localRootPath, allowRoot: true) else { return }
        localPath = normalizedPath(file.path)
        loadLocalFiles()
    }
    
    func navigateLocalUp() {
        guard canNavigateUp else {
            if localRootPath.isEmpty {
                promptForLocalDirectory()
            } else {
                presentError("已到达授权目录的根目录，无法继续向上导航。如需访问其他目录，请重新选择。")
            }
            return
        }
        let url = URL(fileURLWithPath: localPath)
        let parentPath = normalizedPath(url.deletingLastPathComponent().path)
        // 确保不会滑过根目录
        if !isPath(parentPath, inside: localRootPath, allowRoot: true) {
            localPath = localRootPath
        } else {
            localPath = parentPath
        }
        loadLocalFiles()
    }
    
    // MARK: - Remote File Operations
    
    func loadRemoteFiles() async {
        guard let device else { return }
        remoteLoadGeneration &+= 1
        let loadGeneration = remoteLoadGeneration
        let requestedPath = remotePath
        isLoadingRemote = true

        do {
            let files = try await device.listFiles(at: requestedPath)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            guard loadGeneration == remoteLoadGeneration,
                  self.device === device,
                  requestedPath == remotePath else { return }
            remoteFiles = files
            selectedRemoteFiles.removeAll()
        } catch {
            if loadGeneration == remoteLoadGeneration, self.device === device {
                presentError(error.localizedDescription)
            }
        }

        if loadGeneration == remoteLoadGeneration {
            isLoadingRemote = false
        }
    }
    
    func navigateRemote(to file: RemoteFile) {
        guard file.isDirectory,
              isPath(file.path, inside: remoteRootPath, allowRoot: true) else { return }
        remotePath = normalizedPath(file.path)
        Task { await loadRemoteFiles() }
    }
    
    func navigateRemoteUp() {
        guard canNavigateRemoteUp else { return }
        let url = URL(fileURLWithPath: remotePath)
        let parentPath = normalizedPath(url.deletingLastPathComponent().path)
        remotePath = isPath(parentPath, inside: remoteRootPath, allowRoot: true)
            ? parentPath
            : remoteRootPath
        Task { await loadRemoteFiles() }
    }

    // MARK: - Delete and Create Directory

    func requestDelete(_ file: RemoteFile, isLocal: Bool) {
        pendingDeletion = PendingDeletion(
            file: file,
            location: isLocal ? .local : .remote,
            device: isLocal ? nil : device
        )
        showDeleteConfirmation = true
    }

    func cancelDelete() {
        pendingDeletion = nil
    }

    func confirmDelete() {
        guard let deletion = pendingDeletion else { return }
        pendingDeletion = nil
        Task { [weak self] in
            await self?.performDelete(deletion)
        }
    }

    private func performDelete(_ deletion: PendingDeletion) async {
        do {
            switch deletion.location {
            case .local:
                guard isPath(deletion.file.path, inside: localRootPath, allowRoot: false) else {
                    throw DeviceError.permissionDenied("不能删除授权目录的根目录或目录之外的项目")
                }
                let path = deletion.file.path
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.removeItem(atPath: path)
                }.value
                selectedLocalFiles.remove(deletion.file.id)
                loadLocalFiles()

            case .remote:
                guard let device, let expectedDevice = deletion.device,
                      device === expectedDevice, isConnected else {
                    throw DeviceError.notConnected
                }
                guard isPath(deletion.file.path, inside: remoteRootPath, allowRoot: false) else {
                    throw DeviceError.permissionDenied("不能删除设备存储根目录之外的项目")
                }
                try await device.deleteFile(at: deletion.file.path)
                selectedRemoteFiles.remove(deletion.file.id)
                await loadRemoteFiles()
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func requestCreateDirectory(isLocal: Bool) {
        createDirectoryLocation = isLocal ? .local : .remote
        createDirectoryDevice = isLocal ? nil : device
        newDirectoryName = ""
        showCreateDirectoryPrompt = true
    }

    func cancelCreateDirectory() {
        createDirectoryLocation = nil
        createDirectoryDevice = nil
        newDirectoryName = ""
    }

    func confirmCreateDirectory() {
        guard let location = createDirectoryLocation else { return }
        let expectedDevice = createDirectoryDevice
        let name = newDirectoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        createDirectoryLocation = nil
        createDirectoryDevice = nil
        newDirectoryName = ""

        guard isValidFileName(name) else {
            presentError("文件夹名称不能为空，不能是“.”或“..”，也不能包含“/”。")
            return
        }

        Task { [weak self] in
            await self?.createDirectory(
                named: name,
                location: location,
                expectedDevice: expectedDevice
            )
        }
    }

    private func createDirectory(
        named name: String,
        location: FileLocation,
        expectedDevice: DeviceProtocol?
    ) async {
        do {
            switch location {
            case .local:
                guard !localPath.isEmpty else {
                    throw DeviceError.fileNotFound("尚未选择本地目录")
                }
                let url = URL(fileURLWithPath: localPath).appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw DeviceError.processError("同名文件或文件夹已存在：\(name)")
                }
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false
                )
                loadLocalFiles()

            case .remote:
                guard let device, let expectedDevice,
                      device === expectedDevice, isConnected else {
                    throw DeviceError.notConnected
                }
                guard !remoteFiles.contains(where: { $0.name == name }) else {
                    throw DeviceError.processError("同名文件或文件夹已存在：\(name)")
                }
                let path = appendingPathComponent(name, to: remotePath)
                guard isPath(path, inside: remoteRootPath, allowRoot: false) else {
                    throw DeviceError.permissionDenied("目标目录超出设备存储根目录")
                }
                try await device.createDirectory(at: path)
                await loadRemoteFiles()
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }
    
    // MARK: - Transfer
    
    func downloadSelected() {
        let selected = remoteFiles.filter { selectedRemoteFiles.contains($0.id) }
        enqueueDownloads(selected)
        selectedRemoteFiles.removeAll()
    }

    func uploadSelected() {
        let selected = localFiles.filter { selectedLocalFiles.contains($0.id) }
        enqueueUploads(selected)
        selectedLocalFiles.removeAll()
    }

    func downloadFile(_ file: RemoteFile) {
        enqueueDownloads([file])
    }

    func uploadFile(_ file: RemoteFile) {
        enqueueUploads([file])
    }

    private func enqueueDownloads(_ files: [RemoteFile]) {
        guard let device, isConnected, !localPath.isEmpty else { return }
        var reservedDestinations: Set<String> = []

        for file in files where !file.isDirectory {
            let preferredURL = URL(fileURLWithPath: localPath)
                .appendingPathComponent(file.name)
            guard let destination = resolvedLocalDestination(
                preferredURL,
                reserved: reservedDestinations
            ) else { continue }

            reservedDestinations.insert(localPathKey(destination.path))
            transferManager.enqueueDownload(
                remotePath: file.path,
                localURL: destination,
                fileName: destination.lastPathComponent,
                fileSize: file.size,
                device: device
            )
        }
    }

    private func enqueueUploads(_ files: [RemoteFile]) {
        guard let device, isConnected else { return }
        var reservedNames = Set(remoteFiles.map(\.name))

        for file in files where !file.isDirectory {
            let existing = remoteFiles.first(where: { $0.name == file.name })
            let alreadyReserved = reservedNames.contains(file.name) && existing == nil
            var destinationName = file.name
            var overwrite = false

            if existing != nil || alreadyReserved {
                switch conflictPolicy {
                case .skip:
                    continue

                case .rename:
                    destinationName = uniqueFileName(file.name, reserved: reservedNames)

                case .overwrite:
                    if let existing, existing.isDirectory {
                        presentError("无法用文件覆盖同名文件夹：\(file.name)")
                        continue
                    }
                    // Two selected sources must never write the same path in
                    // parallel. A real existing file can be replaced; a name
                    // reserved by this batch is skipped.
                    guard !alreadyReserved else { continue }
                    overwrite = existing != nil
                }
            }

            reservedNames.insert(destinationName)
            transferManager.enqueueUpload(
                localURL: URL(fileURLWithPath: file.path),
                remotePath: appendingPathComponent(destinationName, to: remotePath),
                overwrite: overwrite,
                device: device
            )
        }
    }

    private func resolvedLocalDestination(
        _ preferredURL: URL,
        reserved: Set<String>
    ) -> URL? {
        let preferredPath = normalizedPath(preferredURL.path)
        let preferredKey = localPathKey(preferredPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: preferredPath,
            isDirectory: &isDirectory
        )
        let alreadyReserved = reserved.contains(preferredKey)
        guard exists || alreadyReserved else { return preferredURL }

        switch conflictPolicy {
        case .skip:
            return nil

        case .overwrite:
            guard !alreadyReserved else { return nil }
            if isDirectory.boolValue {
                presentError("无法用文件覆盖同名文件夹：\(preferredURL.lastPathComponent)")
                return nil
            }
            return preferredURL

        case .rename:
            var counter = 1
            while true {
                let name = renamedFileName(preferredURL.lastPathComponent, counter: counter)
                let candidate = preferredURL.deletingLastPathComponent()
                    .appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: candidate.path)
                    && !reserved.contains(localPathKey(candidate.path)) {
                    return candidate
                }
                counter += 1
            }
        }
    }

    private func uniqueFileName(_ originalName: String, reserved: Set<String>) -> String {
        var counter = 1
        while true {
            let candidate = renamedFileName(originalName, counter: counter)
            if !reserved.contains(candidate) { return candidate }
            counter += 1
        }
    }

    private func renamedFileName(_ originalName: String, counter: Int) -> String {
        let name = originalName as NSString
        let fileExtension = name.pathExtension
        let baseName = fileExtension.isEmpty
            ? originalName
            : name.deletingPathExtension
        let suffix = " (\(counter))"
        return fileExtension.isEmpty
            ? "\(baseName)\(suffix)"
            : "\(baseName)\(suffix).\(fileExtension)"
    }

    private func handleTransferFinished(_ task: TransferTask, device: DeviceProtocol) {
        guard self.device === device else { return }
        switch task.direction {
        case .downloadToMac:
            let destinationDirectory = normalizedPath(
                URL(fileURLWithPath: task.destinationPath)
                    .deletingLastPathComponent().path
            )
            guard destinationDirectory == normalizedPath(localPath) else { return }
            guard !hasUnfinishedTransfer(
                direction: .downloadToMac,
                destinationDirectory: destinationDirectory
            ) else { return }
            localRefreshTask?.cancel()
            localRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self,
                      !self.hasUnfinishedTransfer(
                        direction: .downloadToMac,
                        destinationDirectory: destinationDirectory
                      ) else { return }
                self.loadLocalFiles()
            }

        case .uploadToPhone:
            let destinationDirectory = normalizedPath(
                URL(fileURLWithPath: task.destinationPath)
                    .deletingLastPathComponent().path
            )
            guard destinationDirectory == normalizedPath(remotePath), isConnected else { return }
            guard !hasUnfinishedTransfer(
                direction: .uploadToPhone,
                destinationDirectory: destinationDirectory
            ) else { return }
            remoteRefreshTask?.cancel()
            remoteRefreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self,
                      !self.hasUnfinishedTransfer(
                        direction: .uploadToPhone,
                        destinationDirectory: destinationDirectory
                      ) else { return }
                await self.loadRemoteFiles()
            }
        }
    }

    private func hasUnfinishedTransfer(
        direction: TransferDirection,
        destinationDirectory: String
    ) -> Bool {
        transferManager.tasks.contains { task in
            guard task.direction == direction,
                  task.status == .pending || task.status == .inProgress else { return false }
            let directory = normalizedPath(
                URL(fileURLWithPath: task.destinationPath)
                    .deletingLastPathComponent().path
            )
            return directory == destinationDirectory
        }
    }

    // MARK: - Path Helpers

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func localPathKey(_ path: String) -> String {
        normalizedPath(path).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func isPath(_ candidate: String, inside root: String, allowRoot: Bool) -> Bool {
        guard !root.isEmpty else { return false }
        let normalizedCandidate = normalizedPath(candidate)
        let normalizedRoot = normalizedPath(root)
        if normalizedCandidate == normalizedRoot { return allowRoot }
        let prefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        return normalizedCandidate.hasPrefix(prefix)
    }

    private func appendingPathComponent(_ component: String, to parent: String) -> String {
        normalizedPath(
            URL(fileURLWithPath: parent)
                .appendingPathComponent(component)
                .path
        )
    }

    private func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }
    
    // MARK: - Error Handling
    
    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
