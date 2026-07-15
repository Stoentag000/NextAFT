import SwiftUI

/// 路径导航栏
struct PathBar: View {
    let path: String
    var canNavigateUp: Bool = true
    var onUp: () -> Void
    var onRefresh: () -> Void
    var onChooseDirectory: (() -> Void)?
    
    var body: some View {
        HStack(spacing: 6) {
            Button(action: onUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canNavigateUp)
            .help(canNavigateUp ? "返回上级" : "已到达授权目录根")
            
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
            
            if let onChooseDirectory {
                Button(action: onChooseDirectory) {
                    Image(systemName: "folder.badge.gearshape")
                }
                .buttonStyle(.borderless)
                .help("选择目录")
            }
            
            Divider()
                .frame(height: 16)
            
            // 路径显示
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
