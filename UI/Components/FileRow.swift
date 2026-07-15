import SwiftUI

/// 文件行组件
struct FileRow: View {
    let file: RemoteFile
    var onDoubleClick: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 8) {
            // 文件图标
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 20)
            
            // 文件名
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // 文件大小（目录不显示）
            if !file.isDirectory {
                Text(formattedSize)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .onTapGesture(count: 2) {
            onDoubleClick?()
        }
    }
    
    private var iconName: String {
        if file.isDirectory {
            return "folder.fill"
        }
        if file.isImage {
            return "photo"
        }
        if file.isVideo {
            return "film"
        }
        if file.isAudio {
            return "music.note"
        }
        return "doc"
    }
    
    private var iconColor: Color {
        if file.isDirectory { return .blue }
        if file.isImage { return .green }
        if file.isVideo { return .purple }
        if file.isAudio { return .orange }
        return .secondary
    }
    
    private var formattedSize: String {
        let bytes = file.size
        if bytes > 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes > 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes > 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}
