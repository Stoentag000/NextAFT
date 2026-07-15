import SwiftUI

/// 协议选择器
struct ProtocolSelector: View {
    @Binding var selected: ProtocolType
    
    var body: some View {
        Picker("协议", selection: $selected) {
            ForEach(ProtocolType.allCases) { proto in
                Label(proto.rawValue, systemImage: proto.icon)
                    .tag(proto)
                    .help(proto.description)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
    }
}

/// 文件右键菜单
struct FileContextMenu: View {
    let file: RemoteFile
    let isLocal: Bool
    var onTransfer: () -> Void
    
    var body: some View {
        Button {
            onTransfer()
        } label: {
            Label(
                isLocal ? "上传到手机" : "下载到 Mac",
                systemImage: isLocal ? "arrow.up.circle" : "arrow.down.circle"
            )
        }
        
        Divider()
        
        Button {
            // TODO: 实现删除
        } label: {
            Label("删除", systemImage: "trash")
        }
        .foregroundColor(.red)
    }
}
