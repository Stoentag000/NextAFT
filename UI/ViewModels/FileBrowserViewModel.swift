import Foundation
import Combine
import SwiftUI
import AppKit

/// 文件浏览器 ViewModel
@MainActor
final class FileBrowserViewModel: ObservableObject {
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
    /// 授权目录的根路径，不能导航到比这更高的目录
    private(set) var localRootPath: String = ""
    var canNavigateUp: Bool { localPath != localRootPath && !localRootPath.isEmpty }
    
    // MARK: - Selection
    var selectedLocalFiles: Set<UUID> = [] { willSet { objectWillChange.send() } }
    var selectedRemoteFiles: Set<UUID> = [] { willSet { objectWillChange.send() } }
    
    // MARK: - Dependencies
    private var device: DeviceProtocol?
    let transferManager = TransferManager()
    private let usbDetector = USBDeviceDetector()
    
    // MARK: - Initialization
    
    private static let bookmarkKey = "LocalDirectoryBookmark"
    private var securityScopedURL: URL?
    
    func initialize() {
        // 延迟到当前视图更新周期结束后执行，避免 "Publishing changes from within view updates" 警告
        DispatchQueue.main.async { [self] in
            usbDetector.startMonitoring()
            restoreLocalDirectory()
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
        switch selectedProtocol {
        case .mtp:
            device = MTPDevice()
        case .adb:
            device = ADBDevice()
        }
        
        do {
            try await device?.connect()
            isConnected = true
            await loadRemoteFiles()
        } catch {
            presentError(error.localizedDescription)
        }
    }
    
    func disconnect() async {
        try? await device?.disconnect()
        device = nil
        isConnected = false
        remoteFiles = []
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
        guard file.isDirectory else { return }
        localPath = file.path
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
        let parentPath = url.deletingLastPathComponent().path
        // 确保不会滑过根目录
        if !parentPath.hasPrefix(localRootPath) && parentPath != localRootPath {
            localPath = localRootPath
        } else {
            localPath = parentPath
        }
        loadLocalFiles()
    }
    
    // MARK: - Remote File Operations
    
    func loadRemoteFiles() async {
        guard let device else { return }
        isLoadingRemote = true
        
        do {
            remoteFiles = try await device.listFiles(at: remotePath)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        } catch {
            presentError(error.localizedDescription)
        }
        
        isLoadingRemote = false
    }
    
    func navigateRemote(to file: RemoteFile) {
        guard file.isDirectory else { return }
        remotePath = file.path
        Task { await loadRemoteFiles() }
    }
    
    func navigateRemoteUp() {
        let url = URL(fileURLWithPath: remotePath)
        guard url.path != "/" else { return }
        remotePath = url.deletingLastPathComponent().path
        Task { await loadRemoteFiles() }
    }
    
    // MARK: - Transfer
    
    func downloadSelected() {
        guard let device else { return }
        let selected = remoteFiles.filter { selectedRemoteFiles.contains($0.id) }
        
        for file in selected where !file.isDirectory {
            let localURL = URL(fileURLWithPath: localPath).appendingPathComponent(file.name)
            transferManager.enqueueDownload(
                remotePath: file.path,
                localURL: localURL,
                fileName: file.name,
                fileSize: file.size,
                device: device
            )
        }
        selectedRemoteFiles.removeAll()
    }
    
    func uploadSelected() {
        guard let device else { return }
        let selected = localFiles.filter { selectedLocalFiles.contains($0.id) }
        
        for file in selected where !file.isDirectory {
            let remoteDest = remotePath.hasSuffix("/") ? "\(remotePath)\(file.name)" : "\(remotePath)/\(file.name)"
            transferManager.enqueueUpload(
                localURL: URL(fileURLWithPath: file.path),
                remotePath: remoteDest,
                device: device
            )
        }
        selectedLocalFiles.removeAll()
    }
    
    func downloadFile(_ file: RemoteFile) {
        guard let device, !file.isDirectory else { return }
        let localURL = URL(fileURLWithPath: localPath).appendingPathComponent(file.name)
        transferManager.enqueueDownload(
            remotePath: file.path,
            localURL: localURL,
            fileName: file.name,
            fileSize: file.size,
            device: device
        )
    }
    
    func uploadFile(_ file: RemoteFile) {
        guard let device, !file.isDirectory else { return }
        let remoteDest = remotePath.hasSuffix("/") ? "\(remotePath)\(file.name)" : "\(remotePath)/\(file.name)"
        transferManager.enqueueUpload(
            localURL: URL(fileURLWithPath: file.path),
            remotePath: remoteDest,
            device: device
        )
    }
    
    // MARK: - Error Handling
    
    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
