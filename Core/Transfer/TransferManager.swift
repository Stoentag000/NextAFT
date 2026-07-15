import Foundation
import Combine

/// 传输任务管理器
@MainActor
final class TransferManager: ObservableObject {
    let objectWillChange = PassthroughSubject<Void, Never>()
    
    var tasks: [TransferTask] = [] {
        willSet { objectWillChange.send() }
    }
    
    var activeTaskCount: Int = 0 {
        willSet { objectWillChange.send() }
    }
    
    private let maxConcurrent = 3
    private var taskQueue: [TransferTask] = []
    
    /// 添加下载任务（手机 → Mac）
    func enqueueDownload(
        remotePath: String,
        localURL: URL,
        fileName: String,
        fileSize: UInt64,
        device: DeviceProtocol
    ) {
        let task = TransferTask(
            sourcePath: remotePath,
            destinationPath: localURL.path,
            fileName: fileName,
            fileSize: fileSize,
            direction: .downloadToMac
        )
        tasks.append(task)
        taskQueue.append(task)
        processQueue(device: device)
    }
    
    /// 添加上传任务（Mac → 手机）
    func enqueueUpload(
        localURL: URL,
        remotePath: String,
        device: DeviceProtocol
    ) {
        let fileName = localURL.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        
        let task = TransferTask(
            sourcePath: localURL.path,
            destinationPath: remotePath,
            fileName: fileName,
            fileSize: fileSize,
            direction: .uploadToPhone
        )
        tasks.append(task)
        taskQueue.append(task)
        processQueue(device: device)
    }
    
    private func processQueue(device: DeviceProtocol) {
        guard activeTaskCount < maxConcurrent, !taskQueue.isEmpty else { return }
        
        let task = taskQueue.removeFirst()
        activeTaskCount += 1
        
        Task {
            var mutableTask = task
            mutableTask.status = .inProgress
            updateTask(mutableTask)
            
            do {
                let progressHandler: (Double) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        self?.updateProgress(taskId: task.id, progress: progress)
                    }
                }
                
                switch task.direction {
                case .downloadToMac:
                    try await device.download(
                        from: task.sourcePath,
                        to: URL(fileURLWithPath: task.destinationPath),
                        progress: progressHandler
                    )
                case .uploadToPhone:
                    try await device.upload(
                        from: URL(fileURLWithPath: task.sourcePath),
                        to: task.destinationPath,
                        progress: progressHandler
                    )
                }
                
                mutableTask.status = .completed
                mutableTask.progress = 1.0
                mutableTask.endDate = Date()
            } catch {
                mutableTask.status = .failed(error.localizedDescription)
                mutableTask.endDate = Date()
            }
            
            updateTask(mutableTask)
            activeTaskCount -= 1
            processQueue(device: device)
        }
    }
    
    private func updateTask(_ task: TransferTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        }
    }
    
    private func updateProgress(taskId: UUID, progress: Double) {
        if let index = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[index].progress = progress
            tasks[index].transferredBytes = UInt64(progress * Double(tasks[index].fileSize))
        }
    }
    
    func cancelTask(_ task: TransferTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].status = .cancelled
        }
        taskQueue.removeAll { $0.id == task.id }
    }
    
    func clearCompleted() {
        tasks.removeAll {
            if case .completed = $0.status { return true }
            if case .cancelled = $0.status { return true }
            return false
        }
    }
}
