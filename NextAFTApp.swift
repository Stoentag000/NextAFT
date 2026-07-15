import SwiftUI

@main
struct NextAFTApp: App {
    var body: some Scene {
        WindowGroup {
            FileBrowserView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 700)
    }
}
