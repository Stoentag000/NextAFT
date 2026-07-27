import SwiftUI

/// 传输任务列表
struct TransferListView: View {
    @ObservedObject var manager: TransferManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("传输队列")
                    .font(.headline)
                
                Spacer()
                
                Button("清除已完成") {
                    manager.clearCompleted()
                }
                .disabled(!manager.tasks.contains(where: {
                    if case .completed = $0.status { return true }
                    if case .cancelled = $0.status { return true }
                    return false
                }))
                
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            
            Divider()
            
            if manager.tasks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("暂无传输任务")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.tasks) { task in
                    TransferTaskRow(task: task) {
                        manager.cancelTask(task)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 500, height: 400)
    }
}

/// 单个传输任务行
struct TransferTaskRow: View {
    let task: TransferTask
    var onCancel: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // 方向图标
            Image(systemName: task.direction == .downloadToMac ? "arrow.down" : "arrow.up")
                .foregroundStyle(task.direction == .downloadToMac ? .blue : .green)
                .frame(width: 16)
            
            // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    
                    if task.status == .inProgress {
                        Text(task.speedDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // 进度
            if task.status == .inProgress {
                ProgressView(value: task.progress)
                    .frame(width: 100)
                Text("\(Int(task.progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            if task.status == .pending || task.status == .inProgress {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var statusText: String {
        switch task.status {
        case .pending: return "等待中"
        case .inProgress: return "传输中"
        case .completed: return "已完成"
        case .failed(let msg): return "失败: \(msg)"
        case .cancelled: return "已取消"
        }
    }
    
    private var statusColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}
