import Foundation

/// 统一文件模型，屏蔽 MTP/ADB 的差异
struct RemoteFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: UInt64
    let isDirectory: Bool
    let modifiedDate: Date?
    let mimeType: String?
    
    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
    
    var isImage: Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"].contains(fileExtension)
    }
    
    var isVideo: Bool {
        ["mp4", "mov", "mkv", "avi", "webm", "3gp"].contains(fileExtension)
    }
    
    var isAudio: Bool {
        ["mp3", "flac", "wav", "aac", "ogg", "m4a"].contains(fileExtension)
    }
}
