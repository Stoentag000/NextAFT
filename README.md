# NextAFT

- 由于Apple将在未来取消Rosetta转译层，现有的Android File Transfer可能无法运行
- 我为此使用Xiaomi MiMo Claw开发了这款下一代的Android File Transfer
- NextAFT是一款macOS 端 Android 文件传输工具，通过 USB 连接 Android 手机，实现双向文件管理与传输的工具。
- 请注意，当前仍处于早期开发版本，无法正常使用

## 功能

- **双面板文件浏览器** — 左侧 Mac 本地文件，右侧 Android 远程文件
- **双协议支持** — ADB（需开启 USB 调试）/ MTP（直连 USB）
- **文件传输** — 支持上传/下载，传输队列最多 3 个并发任务，实时进度与速度显示
- **文件操作** — 浏览、进入目录、返回上级、右键菜单（上传/下载/删除）
- **目录授权** — macOS 沙盒下通过 NSOpenPanel 选择本地目录，Security-Scoped Bookmark 持久化

## 系统要求

- macOS 14.0+
- Xcode 26+
- Swift 5.0+
- ADB 模式需要安装 [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)

## 构建

1. 克隆项目
2. 用 Xcode 打开 `NextAFT.xcodeproj`
3. 选择目标设备 → Build & Run

ADB 路径会自动按以下顺序查找：
1. App Bundle 内嵌
2. `/usr/local/bin/adb`
3. `/opt/homebrew/bin/adb`
4. `~/Library/Android/sdk/platform-tools/adb`
5. 系统 PATH

## 项目结构

```
NextAFT/
├── NextAFTApp.swift                    # App 入口
├── NextAFT-Bridging.h                  # libmtp C 桥接头（预留）
│
├── Core/                               # 核心业务逻辑
│   ├── Models/                         # 数据模型
│   │   ├── DeviceError.swift           # 设备错误定义
│   │   ├── DeviceInfo.swift            # 设备信息模型
│   │   ├── ProtocolType.swift          # 协议类型枚举 (MTP/ADB)
│   │   ├── RemoteFile.swift            # 统一文件模型
│   │   └── TransferTask.swift          # 传输任务模型
│   ├── Protocol/                       # 设备协议层
│   │   ├── DeviceProtocol.swift        # 统一协议接口
│   │   ├── ADB/ADBDevice.swift         # ADB 协议实现
│   │   └── MTP/MTPDevice.swift         # MTP 协议实现（TODO）
│   ├── Transfer/
│   │   └── TransferManager.swift       # 传输队列管理
│   └── USB/
│       └── USBDeviceDetector.swift     # USB 设备检测（TODO）
│
├── UI/                                 # SwiftUI 视图层
│   ├── Components/                     # 可复用 UI 组件
│   │   ├── FileRow.swift               # 文件行（图标+名称+大小）
│   │   ├── PathBar.swift               # 路径导航栏
│   │   └── ToolbarComponents.swift     # 协议选择器 + 右键菜单
│   ├── ViewModels/
│   │   └── FileBrowserViewModel.swift  # 文件浏览器 ViewModel
│   └── Views/
│       ├── FileBrowserView.swift       # 主视图（双面板布局）
│       └── TransferListView.swift      # 传输队列弹窗
│
├── Resources/
│   └── Info.plist
│
└── NextAFT.xcodeproj/
```

## 架构

MVVM 分层，协议驱动：

```
Models → Protocol(接口) → Devices(实现) → Services → ViewModel → Views
```

- `DeviceProtocol` 定义统一接口，ADB/MTP 各自实现
- `TransferManager` 管理传输队列，支持并发、进度、取消
- `FileBrowserViewModel` 协调本地/远程文件操作与 UI 状态
- 视图层纯 SwiftUI，`NavigationSplitView` 双面板

## 许可证

Copyright © 2026. All rights reserved.
