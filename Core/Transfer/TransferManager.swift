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
    private struct QueueItem {
        let task: TransferTask
        let device: DeviceProtocol
        let overwrite: Bool
        let cancellation: TransferCancellationToken
    }

    private struct ActiveTransfer {
        let device: DeviceProtocol
        let cancellation: TransferCancellationToken
        let operation: Task<Void, Never>
    }

    private var taskQueue: [QueueItem] = []
    private var activeTransfers: [UUID: ActiveTransfer] = [:]
    var onTaskFinished: ((TransferTask, DeviceProtocol) -> Void)?
    
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
        taskQueue.append(QueueItem(
            task: task,
            device: device,
            overwrite: true,
            cancellation: TransferCancellationToken()
        ))
        processQueue()
    }
    
    /// 添加上传任务（Mac → 手机）
    func enqueueUpload(
        localURL: URL,
        remotePath: String,
        overwrite: Bool,
        device: DeviceProtocol
    ) {
        let fileName = URL(fileURLWithPath: remotePath).lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        
        let task = TransferTask(
            sourcePath: localURL.path,
            destinationPath: remotePath,
            fileName: fileName,
            fileSize: fileSize,
            direction: .uploadToPhone
        )
        tasks.append(task)
        taskQueue.append(QueueItem(
            task: task,
            device: device,
            overwrite: overwrite,
            cancellation: TransferCancellationToken()
        ))
        processQueue()
    }
    
    private func processQueue() {
        while activeTransfers.count < maxConcurrent, !taskQueue.isEmpty {
            let item = taskQueue.removeFirst()
            guard let index = tasks.firstIndex(where: { $0.id == item.task.id }),
                  tasks[index].status == .pending else { continue }

            tasks[index].status = .inProgress
            let operation = Task { [weak self] in
                guard let self else { return }
                await self.execute(item)
            }
            activeTransfers[item.task.id] = ActiveTransfer(
                device: item.device,
                cancellation: item.cancellation,
                operation: operation
            )
        }
        activeTaskCount = activeTransfers.count
    }

    private func execute(_ item: QueueItem) async {
        let task = item.task
        do {
            try item.cancellation.checkCancellation()
            let progressHandler: (Double) -> Void = { [weak self] progress in
                Task { @MainActor in
                    self?.updateProgress(taskId: task.id, progress: progress)
                }
            }

            switch task.direction {
            case .downloadToMac:
                try await item.device.download(
                    from: task.sourcePath,
                    to: URL(fileURLWithPath: task.destinationPath),
                    progress: progressHandler,
                    cancellation: item.cancellation
                )
            case .uploadToPhone:
                try await item.device.upload(
                    from: URL(fileURLWithPath: task.sourcePath),
                    to: task.destinationPath,
                    overwrite: item.overwrite,
                    progress: progressHandler,
                    cancellation: item.cancellation
                )
            }

            try item.cancellation.checkCancellation()
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index].status = .completed
                tasks[index].progress = 1.0
                tasks[index].transferredBytes = tasks[index].fileSize
                tasks[index].endDate = Date()
            }
        } catch {
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                if item.cancellation.isCancellationRequested ||
                    error is CancellationError || Task.isCancelled {
                    tasks[index].status = .cancelled
                } else {
                    tasks[index].status = .failed(error.localizedDescription)
                }
                tasks[index].endDate = Date()
            }
        }

        activeTransfers.removeValue(forKey: task.id)
        activeTaskCount = activeTransfers.count
        if let finishedTask = tasks.first(where: { $0.id == task.id }) {
            onTaskFinished?(finishedTask, item.device)
        }
        processQueue()
    }
    
    private func updateProgress(taskId: UUID, progress: Double) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[index].status == .inProgress else { return }
        let value = min(max(progress, 0), 1)
        tasks[index].progress = value
        tasks[index].transferredBytes = UInt64(value * Double(tasks[index].fileSize))
    }
    
    func cancelTask(_ task: TransferTask) {
        cancelTask(id: task.id)
    }

    func cancelTasks(for device: DeviceProtocol) {
        let queuedIDs = taskQueue
            .filter { $0.device === device }
            .map(\.task.id)
        let activeIDs = activeTransfers
            .filter { $0.value.device === device }
            .map(\.key)
        for id in Set(queuedIDs + activeIDs) {
            cancelTask(id: id)
        }
    }

    private func cancelTask(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].status == .pending ||
                tasks[index].status == .inProgress else { return }

        let queued = taskQueue.filter { $0.task.id == id }
        taskQueue.removeAll { $0.task.id == id }
        queued.forEach { $0.cancellation.cancel() }

        if let active = activeTransfers[id] {
            active.cancellation.cancel()
            active.operation.cancel()
        }

        tasks[index].status = .cancelled
        tasks[index].endDate = Date()
        if let queuedDevice = queued.first?.device {
            onTaskFinished?(tasks[index], queuedDevice)
        }
        processQueue()
    }
    
    func clearCompleted() {
        tasks.removeAll {
            if case .completed = $0.status { return true }
            if case .cancelled = $0.status { return true }
            return false
        }
    }
}
