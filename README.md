# NextAFT

NextAFT 是一款 macOS Android 文件传输工具，通过 USB 连接 Android 设备，
提供本地与手机之间的双向文件浏览和传输。项目旨在提供原版 Android File
Transfer 的原生替代方案，并同时支持 ADB 与 MTP。

> 当前仍处于早期开发阶段。项目已经通过构建和无设备启动测试，但 ADB/MTP
> 的真机传输、传输取消及不同厂商设备兼容性仍需要继续验证。

## 功能

- **双面板文件浏览器** — 左侧 Mac 本地文件，右侧 Android 远程文件
- **双协议支持** — ADB（需开启 USB 调试）/ MTP（直连 USB）
- **文件传输** — 支持上传/下载，显示实时进度与速度
- **传输队列** — 最多启动 3 个任务；ADB 可并行，MTP 为保证会话安全在底层串行执行
- **传输取消** — 支持取消等待中或传输中的任务，断开设备时自动取消其关联任务
- **安全落盘** — ADB/MTP 下载使用临时文件，成功后才替换目标文件
- **文件浏览** — 支持进入目录、返回上级、刷新以及右键上传/下载
- **目录授权** — 通过 NSOpenPanel 选择本地目录，并使用 Bookmark 持久化

删除文件和创建目录的协议接口已经实现，但界面入口尚未完成。

## 系统要求

- macOS 14.0+
- Xcode 26+
- Swift 5.0+
- CMake 3.10+ (`brew install cmake`)
- ADB 模式需要安装 [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)

## 使用

### ADB 模式

1. 在 Android 设备上开启“开发者选项”和“USB 调试”。
2. 连接 USB 后，在手机上允许此 Mac 的调试授权。
3. 在 NextAFT 中选择 ADB，然后点击“连接”。

如果设备显示为 `unauthorized`，请解锁手机并确认 USB 调试授权弹窗。

### MTP 模式

1. 连接 USB 并解锁 Android 设备。
2. 将手机的 USB 用途切换为“文件传输”或“MTP”。
3. 关闭其他正在占用该 MTP 设备的文件传输程序。
4. 在 NextAFT 中选择 MTP，然后点击“连接”。

首次启动时，NextAFT 会要求选择一个本地文件夹。应用只在该目录及其子目录中
浏览和传输本地文件。

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
2. `$ANDROID_HOME/platform-tools/adb`
3. `$ANDROID_SDK_ROOT/platform-tools/adb`
4. `/usr/local/bin/adb`
5. `/opt/homebrew/bin/adb`
6. `~/Library/Android/sdk/platform-tools/adb`
7. 系统 PATH（由应用显式解析为绝对路径）

## 当前状态与验证

构建与模拟验证已经完成：

- AFTL 静态库的 arm64/x86_64 universal 构建
- macOS arm64 Debug 和 x86_64 Release 构建
- ADB server 无设备启动测试及可读错误反馈
- AFTL 无设备连接失败测试
- 多设备队列绑定、等待任务取消和活跃任务取消模拟测试

仍需真机验证：

- ADB/MTP 上传、下载及中途取消
- 大文件、Unicode 文件名和同名文件处理
- 锁屏、拔线、授权变化和传输中断恢复
- Samsung、Google、小米、OPPO、vivo、华为等不同厂商设备

当前限制：

- MTP 只使用第一个检测到的设备和第一个存储空间
- MTP 传输在单个 USB 会话上串行执行
- 删除和创建目录暂时没有界面入口
- 传输完成后文件列表不会自动刷新

## 项目结构

```
NextAFT/
├── NextAFTApp.swift                    # App 入口
├── NextAFT-Bridging.h                  # Swift-C 桥接头（引入 AFTLWrapper.h）
├── NextAFT.entitlements                # USB 权限和签名配置
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
│       └── ContinuationBox.swift       # 预留的线程安全 Continuation 包装
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
- `TransferManager` 将任务绑定到创建它的设备，并管理并发、进度和取消令牌
- `FileBrowserViewModel` 协调本地/远程文件操作与 UI 状态
- 视图层纯 SwiftUI，`NavigationSplitView` 双面板

ADB 取消会终止对应的 `adb` 子进程。MTP 取消通过带传输 ID 的 AFTL 桥发送
CancelTransaction；传输 ID 可以防止迟到的取消请求中断下一项任务。

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

NextAFT 应用代码 Copyright © 2026。除另有说明外，保留所有权利。

项目 vendored 的 `android-file-transfer-linux`（AFTL）使用 GNU Lesser General
Public License 2.1 或更高版本，完整许可文本见
[`Vendor/aftl/LICENSE`](Vendor/aftl/LICENSE)。当前构建会静态链接 AFTL；分发应用时
需要同时提供相应许可声明，并满足 LGPL 对库源码、修改内容以及用户重新链接能力
等方面的要求。发布前应对最终分发方式进行许可证合规审查。
