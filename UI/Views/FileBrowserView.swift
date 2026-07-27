import SwiftUI

/// 主文件浏览器视图 — 双面板布局
struct FileBrowserView: View {
    @StateObject private var viewModel = FileBrowserViewModel()
    @State private var showTransferPanel = false
    
    var body: some View {
        NavigationSplitView {
            // 左侧：本地文件（Mac）
            LocalFilePanel(viewModel: viewModel)
        } detail: {
            // 右侧：远程文件（Android）
            RemoteFilePanel(viewModel: viewModel)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ProtocolSelector(selected: $viewModel.selectedProtocol)
                    .disabled(viewModel.isConnected || viewModel.isConnecting)

                ConflictPolicySelector(selected: $viewModel.conflictPolicy)
                
                Button {
                    Task { 
                        if viewModel.isConnected || viewModel.isConnecting {
                            await viewModel.disconnect()
                        } else {
                            await viewModel.connect()
                        }
                    }
                } label: {
                    Label(
                        viewModel.isConnected
                            ? "断开"
                            : (viewModel.isConnecting ? "取消连接" : "连接"),
                        systemImage: viewModel.isConnected
                            ? "link.circle.fill"
                            : (viewModel.isConnecting ? "ellipsis.circle" : "link.circle")
                    )
                }
                .tint(viewModel.isConnected ? .red : (viewModel.isConnecting ? .orange : .green))
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showTransferPanel.toggle()
                } label: {
                    Label("传输队列", systemImage: "arrow.triangle.2.circlepath")
                        .badge(viewModel.transferManager.activeTaskCount)
                }
            }
        }
        .sheet(isPresented: $showTransferPanel) {
            TransferListView(manager: viewModel.transferManager)
        }
        .onAppear {
            viewModel.initialize()
        }
        .onDisappear {
            viewModel.shutdown()
        }
        .alert("删除项目", isPresented: $viewModel.showDeleteConfirmation) {
            Button("取消", role: .cancel) {
                viewModel.cancelDelete()
            }
            Button("删除", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            Text(viewModel.deleteConfirmationMessage)
        }
        .alert("新建文件夹", isPresented: $viewModel.showCreateDirectoryPrompt) {
            TextField("文件夹名称", text: $viewModel.newDirectoryName)
            Button("取消", role: .cancel) {
                viewModel.cancelCreateDirectory()
            }
            Button("创建") {
                viewModel.confirmCreateDirectory()
            }
        } message: {
            Text("请输入新文件夹名称。")
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定") {}
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
    }
}

// MARK: - 本地文件面板

struct LocalFilePanel: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // 路径导航栏
            PathBar(
                path: viewModel.localPath,
                canNavigateUp: viewModel.canNavigateUp,
                onUp: { viewModel.navigateLocalUp() },
                onRefresh: { viewModel.loadLocalFiles() },
                onChooseDirectory: { viewModel.promptForLocalDirectory() },
                onCreateDirectory: { viewModel.requestCreateDirectory(isLocal: true) }
            )
            
            Divider()
            
            // 文件列表
            if viewModel.isLoadingLocal {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.localFiles, selection: $viewModel.selectedLocalFiles) { file in
                    FileRow(file: file) {
                        viewModel.navigateLocal(to: file)
                    }
                    .contextMenu {
                        FileContextMenu(
                            file: file,
                            isLocal: true,
                            onTransfer: { viewModel.uploadFile(file) },
                            onDelete: { viewModel.requestDelete(file, isLocal: true) }
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            Divider()
            
            // 底部操作栏
            HStack {
                Text("\(viewModel.localFiles.count) 项")
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("上传选中") {
                    viewModel.uploadSelected()
                }
                .disabled(viewModel.selectedLocalFiles.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(8)
        }
        .navigationTitle("Mac")
    }
}

// MARK: - 远程文件面板

struct RemoteFilePanel: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // 路径导航栏
            PathBar(
                path: viewModel.remotePath,
                canNavigateUp: viewModel.canNavigateRemoteUp,
                onUp: { viewModel.navigateRemoteUp() },
                onRefresh: { Task { await viewModel.loadRemoteFiles() } },
                onCreateDirectory: viewModel.isConnected
                    ? { viewModel.requestCreateDirectory(isLocal: false) }
                    : nil
            )
            
            Divider()
            
            if !viewModel.isConnected {
                // 未连接状态
                VStack(spacing: 16) {
                    Image(systemName: "smartphone")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    
                    Text("未连接设备")
                        .font(.title2)
                    
                    Text(viewModel.usbStatusDescription)
                        .foregroundStyle(.secondary)

                    if viewModel.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    
                    Button(viewModel.isConnecting ? "取消连接" : "连接") {
                        Task {
                            if viewModel.isConnecting {
                                await viewModel.disconnect()
                            } else {
                                await viewModel.connect()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isLoadingRemote {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.remoteFiles, selection: $viewModel.selectedRemoteFiles) { file in
                    FileRow(file: file) {
                        viewModel.navigateRemote(to: file)
                    }
                    .contextMenu {
                        FileContextMenu(
                            file: file,
                            isLocal: false,
                            onTransfer: { viewModel.downloadFile(file) },
                            onDelete: { viewModel.requestDelete(file, isLocal: false) }
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            Divider()
            
            // 底部操作栏
            HStack {
                Text("\(viewModel.remoteFiles.count) 项")
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("下载选中") {
                    viewModel.downloadSelected()
                }
                .disabled(viewModel.selectedRemoteFiles.isEmpty || !viewModel.isConnected)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            .padding(8)
        }
        .navigationTitle("Android")
    }
}
