# NextAFT

- 由于Apple将在未来取消Rosetta转译层，现有的Android File Transfer可能无法运行
- 我为此使用Xiaomi MiMo Claw开发了这款下一代的Android File Transfer
- NextAFT是一款macOS 端 Android 文件传输工具，通过 USB 连接 Android 手机，实现双向文件管理与传输的工具。
- 请注意，当前仍处于早期开发版本，MTP 功能需要在不同 Android 设备上继续验证

## 功能

- **双面板文件浏览器** — 左侧 Mac 本地文件，右侧 Android 远程文件
- **双协议支持** — ADB（需开启 USB 调试）/ MTP（直连 USB）
- **文件传输** — 支持上传/下载，传输队列最多 3 个并发任务，实时进度与速度显示
- **文件操作** — 浏览、进入目录、返回上级、右键菜单（上传/下载/删除）
- **目录授权** — 通过 NSOpenPanel 选择本地目录，并使用 Bookmark 持久化

## 系统要求

- macOS 14.0+
- Xcode 26+
- Swift 5.0+
- CMake 3.10+ (`brew install cmake`)
- ADB 模式需要安装 [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)

## 构建

### 1. 克隆项目

```bash
git clone <repo-url>
cd NextAFT
```

AFTL 源码已经 vendored 在 `Vendor/aftl/`，不需要额外初始化子模块。

### 2. 编译 AFTL（MTP 支持）

```bash
./build_aftl.sh
```

这会为 arm64 和 x86_64 编译通用的 android-file-transfer-linux 静态库，输出到
`Vendor/aftl-output/`。只在 Apple Silicon 本机开发时可使用
`AFTL_ARCHS=arm64 ./build_aftl.sh` 缩短构建时间。

### 3. 用 Xcode 打开并构建

1. 用 Xcode 打开 `NextAFT.xcodeproj`
2. 选择目标设备 → Build & Run

头文件、静态库、IOKit、CoreFoundation、Bridging Header 和 USB 权限都已在工程中配置。

> 当前 ADB 模式会调用 Android SDK 中的外部 `adb`，因此 App Sandbox 已关闭，
> Hardened Runtime 仍然启用，适合签名、公证后站外分发。如果未来需要发布到
> Mac App Store，应将 `adb` 改为 App Bundle 内嵌且正确签名的 helper。

ADB 路径会自动按以下顺序查找：
1. App Bundle 内嵌
2. `/usr/local/bin/adb`
3. `/opt/homebrew/bin/adb`
4. `~/Library/Android/sdk/platform-tools/adb`
5. 系统 PATH（由应用显式解析为绝对路径）

## 项目结构

```
NextAFT/
├── NextAFTApp.swift                    # App 入口
├── NextAFT-Bridging.h                  # Swift-C 桥接头（引入 AFTLWrapper.h）
├── build_aftl.sh                       # AFTL 静态库编译脚本
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
│   │   └── MTP/
│   │       ├── MTPDevice.swift         # MTP 协议实现（Swift）
│   │       └── AFTLBridge/
│   │           ├── AFTLWrapper.h       # 纯 C 桥接接口
│   │           └── AFTLWrapper.cpp     # C++ 实现（调用 AFTL 库）
│   ├── Transfer/
│   │   └── TransferManager.swift       # 传输队列管理
│   ├── USB/
│   │   └── USBDeviceDetector.swift     # USB 设备检测（IOKit）
│   └── Utils/
│       └── ContinuationBox.swift       # 线程安全的 Continuation 包装
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
├── Vendor/                             # vendored 第三方依赖
│   ├── aftl/                           # android-file-transfer-linux 源码
│   └── aftl-output/                    # 编译产物（.a + headers）
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

### MTP 协议栈

```
Swift (MTPDevice.swift)
  ↓ 调用纯 C 函数
AFTLWrapper.h / .cpp   (C++ 桥接层)
  ↓ 调用 C++ 类
libmtp-ng-static.a     (android-file-transfer-linux 编译产物)
  ↓ IOKit USB 通信
Android 设备
```

## 许可证

Copyright © 2026. All rights reserved.
