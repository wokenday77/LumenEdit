# LumenEdit

自用 iOS 修图 App。对标醒图的核心体验，功能范围可控。

- **媒体**：照片 / Live Photo / 视频 的拍摄、编辑与导出
- **技术栈**：Swift + SwiftUI（相机与视频预览用 `UIViewRepresentable` 包 UIKit）
- **框架**：AVFoundation + Core Image + Photos / PhotosUI，**零第三方依赖**
- **目标设备**：iPhone 16 系列及以上，最低 iOS 18.0，仅竖屏

---

## 当前进度

| 阶段 | 范围 | 状态 |
|---|---|---|
| **P1a** | 照片采集闭环：权限、取景、点按对焦、曝光补偿、快门、原始 HEIC 直存相册、相机控制按钮全按快门 | ✅ 已通过云端 CI 编译，待真机验证 |
| **P1b-1** | **Live Photo 拍摄**：同一个 PhotoOutput 开启 Live 采集、静态照片与配对视频按 uniqueID 配对、成对入库 | ✅ 已通过云端 CI 编译，待真机验证 |
| P1b-2 | 视频录制（`AVCaptureMovieFileOutput`）+ 录制指示 + 录制中禁止拍照 | 待做 |
| P2 | ISO / 快门 / 白平衡手动档、镜头切换与变焦、格式帧率选择、相机控制按钮轻按滑杆、修图页预设注入 | 待做 |
| P3 | 媒体导入（PHPicker + PHAsset 类型识别 + Live Photo 双资源解析） | 待做 |
| P4 | 修图引擎（10 项调整 + ≥10 款滤镜 + 实时预览）+ 照片导出 | 待做 |
| P5 | Live Photo 编辑与配对导出（`PHLivePhotoEditingContext` 逐帧） | 待做 |
| P6 | 视频编辑（裁剪 / 变速 / 逐帧滤镜 / MOV 导出保留音频） | 待做 |
| P7 | 人像 / 景深（可选，暂不排期） | 未定 |

---

## 一、完整文件清单

### 工程与工具（7 个）

| 文件 | 作用 |
|---|---|
| `project.yml` | **XcodeGen 工程定义，唯一的工程真源**。`.xcodeproj` 由它生成，不入库 |
| `.gitignore` | 忽略 `*.xcodeproj/`、`build/`、`DerivedData/`、本地签名配置、`.workbuddy/`、`*.zip` |
| `.github/workflows/build.yml` | push 即在 GitHub `macos-15` runner 上无签名编译一次（公开仓库分钟数无限） |
| `README.md` | 本文件 |
| `CONTEXT_HOT.md` | 对话续接摘要（换会话/换机器时整份贴出即可续上） |
| `tools/check_prototype.js` | 原型自检 8 组：JS 语法、标签/CSS 配平、数据完整性、SVG、布局预算与互斥规则、对标元素 |
| `tools/check_swift.js` | Swift 结构自检 4 组：括号配平、顶层类型重名、占位符、未来类型引用 |
| `tools/make_app_icon.py` | 纯标准库生成 1024×1024 App 图标（不依赖 Pillow），换配色改常量重跑即可 |

### 资源（6 个）

| 文件 | 作用 |
|---|---|
| `LumenEdit/Resources/Info.plist` | 4 条权限用途说明、仅竖屏、`arm64`、启动画面、状态栏样式 |
| `LumenEdit/Resources/PrivacyInfo.xcprivacy` | 隐私清单：UserDefaults / 文件时间戳 / 磁盘空间 三项必需理由 API |
| `LumenEdit/Resources/Assets.xcassets/Contents.json` | 资源目录根 |
| `…/AppIcon.appiconset/Contents.json` | App 图标声明（单尺寸 1024） |
| `…/AppIcon.appiconset/AppIcon1024.png` | 实际图标位图（脚本生成） |
| `…/AccentColor.colorset/Contents.json` | 强调色（浅色/深色两套） |

### App 层（3 个）

| 文件 | 作用 |
|---|---|
| `App/LumenEditApp.swift` | `@main` 入口。装配依赖容器、启动日志系统、把前后台事件转发给相机会话 |
| `App/AppEnvironment.swift` | 全局依赖容器：`PermissionManager` / `RenderContext` / `ThumbnailCache` / `CaptureSessionController` 单例。**保证全局只有一个 session、一个 CIContext** |
| `App/AppRouter.swift` | 根路由 + 设置页（调试浮层开关、权限总览、日志导出/预览） |

### 设计系统（4 个）

| 文件 | 作用 |
|---|---|
| `DesignSystem/Theme.swift` | 颜色 / 间距 / 圆角 / 尺寸 / 字体令牌 |
| `DesignSystem/Haptics.swift` | 触感反馈封装（生成器复用 + 全局开关） |
| `DesignSystem/Components/ParameterSlider.swift` | 通用参数滑块：吸附步长、数值点击归位、居中填充、触感刻度 |
| `DesignSystem/Components/ModeSelector.swift` | 模式切换条（未实现模式置灰加锁）+ `CaptureThumbnail` 相册缩略图 |

### Core 层（10 个）

| 文件 | 作用 |
|---|---|
| `Core/Utils/Log.swift` | 日志中枢：OSLog **+ App 沙盒文件双写**、200 条环形缓冲、512KB 自动裁剪。**侧载运行没有控制台，这是唯一排障手段** |
| `Core/Utils/Numeric+Clamp.swift` | 数值钳制/吸附/去 NaN（硬件参数写入前必过）+ `FormatText` 显示格式化 |
| `Core/Utils/DebugHUD.swift` | `CameraDebugSnapshot` + 屏幕调试浮层（点一下展开看最近日志、可导出） |
| `Core/Utils/DeviceStorage.swift` | 剩余空间查询、按码率估算可录时长、低空间判断 |
| `Core/Permissions/PermissionManager.swift` | 相机/麦克风/相册读写 四路权限三态机，显式 continuation 包装系统回调 |
| `Core/ImagePipeline/RenderContext.swift` | 全局唯一 `CIContext`（Metal 后端、固定工作色彩空间）。P4 起大量使用 |
| `Core/ImagePipeline/ColorSpaces.swift` | 色彩空间约定（线性 sRGB 工作空间 / 输出 P3），避免"导出后颜色变了" |
| `Core/ImagePipeline/ThumbnailCache.swift` | 缩略图缓存：**不解码原图**的降采样，以及无权限时的降级 |
| `Core/MediaIO/PhotoLibraryWriter.swift` | 相册入库唯一出口：照片 / 视频 / **Live Photo 成对提交** |
| `Core/MediaIO/AudioSessionManager.swift` | 音频会话激活与释放（录制场景类别、中断通知、释放时通知其它 App 恢复） |

### Camera 层（15 个）

| 文件 | 作用 |
|---|---|
| `Camera/Session/CaptureSessionMode.swift` | 模式枚举 + 每个模式的麦克风需求 + **实现状态开关**（当前 photo / livePhoto 为 true，video 待 P1b-2） |
| `Camera/Session/CaptureCapabilities.swift` | 能力探测：设备回退链、格式挑选、帧率范围、编码格式。**不写机型判断** |
| `Camera/Session/CapturePreset.swift` | `EditRecipe → CapturePreset → 硬件` 的中间结构，字段一次定义完整 |
| `Camera/Session/CaptureDeviceConfigurator.swift` | **全工程唯一允许 `lockForConfiguration()` 的地方**，负责顺序与钳制 |
| `Camera/Session/CaptureSessionController.swift` | 会话生命周期、模式切换动态增删 output、参数入口、调试快照 |
| `Camera/Output/CaptureResult.swift` | 三种采集产物的归一化模型 |
| `Camera/Output/PhotoCaptureService.swift` | 拍摄门面：settings 模板复制、原始字节直取、等 `didFinishCaptureFor` 才收尾；Live Photo 的两半转发给配对方 |
| `Camera/Output/LivePhotoCaptureService.swift` | Live Photo 拍摄编排：临时 MOV URL、写入 uniqueID 的 settings、收拢两个回调、产出配对结果 |
| `Camera/Output/LivePhotoAssembler.swift` | 配对状态机：按 uniqueID 暂存两半，齐了才交付；顺带清理失败留下的临时文件 |
| `Camera/Hardware/CameraControlButton.swift` | 相机控制按钮全按快门（`AVCaptureEventInteraction`），自管启停 |
| `Camera/UI/PreviewView.swift` | `UIViewRepresentable` 包 `AVCaptureVideoPreviewLayer` + 点按对焦手势 |
| `Camera/UI/FocusIndicatorView.swift` | 对焦方框动画（用 token 驱动，同位置连点也会重播） |
| `Camera/UI/ExposurePanel.swift` | 曝光补偿面板 |
| `Camera/UI/CameraViewModel.swift` | 相机页状态机：权限流程、保存、提示条、模式校验 |
| `Camera/UI/CameraView.swift` | 相机主页（含权限引导页、会话失败重试条、快门按钮） |

**合计 32 个 Swift 文件**（App 3 · 设计系统 4 · Core 10 · Camera 15）**+ 资源 6 个 + 工程/工具 7 个 = 45 个文件。**

---

## 二、在 Mac 上从零跑起来

### 前置：装好两个东西

```bash
# 1) Xcode 16.0 以上（必须有 iOS 18 SDK）
#    从 App Store 装，装完先跑一次，同意许可协议、装附加组件
xcode-select -p          # 应输出 /Applications/Xcode.app/Contents/Developer

# 2) XcodeGen（工程生成器，不是 App 依赖）
brew install xcodegen
xcodegen --version
```

> 没装 Homebrew 就先装：`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

### 第 1 步：把代码放到 Mac 上

```bash
cd ~/Documents
# 方式 A：从 GitHub 克隆（推荐，后续 Actions 也在同一个仓库）
git clone <你的仓库地址> LumenEdit
cd LumenEdit

# 方式 B：从这台 Windows 机器拷过去（U 盘 / 隔空投送 / 网盘）
# 注意：不要拷 .xcodeproj（本来就不存在），也建议不拷 build/ 之类
```

### 第 2 步：生成 Xcode 工程

```bash
cd ~/Documents/LumenEdit
xcodegen generate
```

看到 `Created project at .../LumenEdit.xcodeproj` 就成了。

> `.xcodeproj` **不入库**，所以每次 `git pull` 之后、或增删了文件之后，都要重跑一次
> `xcodegen generate`。这是使用 XcodeGen 的唯一额外习惯。

### 第 3 步：打开并配置签名

```bash
open LumenEdit.xcodeproj
```

在 Xcode 里依次做三件事：

1. 左侧选中蓝色项目图标 → **TARGETS → LumenEdit** → **Signing & Capabilities**
2. 勾上 **Automatically manage signing**，**Team** 选你的 Apple ID
   （没有的话 Xcode → Settings → Accounts → 加一个 Apple ID，免费账号即可）
3. 把 **Bundle Identifier** 改成全局唯一的，例如：
   `com.你的名字拼音.lumenedit`
   ⚠️ 不要用默认的 `com.lumenedit.app` —— 免费签名要求 Bundle ID 全局唯一，大概率已被占用

如果报 "Failed to register bundle identifier"，就是 Bundle ID 撞了，换一个即可。

### 第 4 步：真机连接与信任

1. iPhone 用数据线连 Mac
2. iPhone 上会弹「信任此电脑」→ 信任
3. iPhone 上打开 **设置 → 隐私与安全性 → 开发者模式** → 打开（**需要重启手机**）
4. Xcode 顶部设备栏选中你的 iPhone

> **必须是真机。** 模拟器没有摄像头，这个 App 在模拟器上只能看到权限引导页，
> 相机会话会直接进入「找不到可用的后置摄像头」的失败态。

### 第 5 步：编译运行

顶部选中你的 iPhone → 按 **⌘R**。

第一次装完如果打不开，去 iPhone **设置 → 通用 → VPN与设备管理 → 开发者App** 里信任你的开发者证书。

> **免费 Apple ID 的限制**：签名 **7 天** 有效，到期后 App 会闪退/打不开，
> 重新 ⌘R 装一次即可。想省事就上付费开发者账号（¥688/年，1 年有效）。

### 第 6 步：按验收清单过一遍

见下方「P1a 验收清单」。

---

## 三、验收清单（真机逐项过）—— P1a + P1b-1

权限与取景
- [ ] 冷启动 → 相机权限弹窗 → 允许 → 取景画面 1 秒内出现，滑动流畅
- [ ] 拒绝相机权限 → 出现引导页 → 点按钮跳到系统设置 → 开启后回到 App 自动恢复
- [ ] 切后台再回前台：取景自动恢复，不需要重启 App

拍摄
- [ ] 点按画面任意位置 → 出现黄色对焦方框 → 焦点实际变化（远近物体各试一次）
- [ ] 拖动曝光补偿滑块 → 画面亮度实时变化；点数值可归零
- [ ] 点快门 → 内圈收缩 → 左下角缩略图更新 → 系统相册能看到新照片
- [ ] 相册里查看该照片：EXIF 完整（机型 / 光圈 / 快门 / 时间 / GPS）
- [ ] 连拍 20 张：不崩不卡，每张都进相册

Live Photo（P1b-1）
- [ ] 点模式条「Live」→ **不再有锁图标**，顶栏出现 `LIVE` 标记
- [ ] 第一次切到 Live 时会弹**麦克风权限**（Live Photo 需要音轨，没权限就没有声音）
- [ ] 拍一张 → 提示「Live Photo 已保存」→ 打开系统相册，**长按能播放动图**，角标是 Live
- [ ] ⚠️ **不是「一张静态图 + 一段孤立视频」** —— 这是配对失败最典型的表现，出现就是 bug
- [ ] 静态帧清晰、有声音、时长约 3 秒
- [ ] 连拍 10 张 Live Photo → 全部被识别成 Live Photo（验证配对状态机不串号）
- [ ] 切回「照片」模式再拍 → 存进去的是普通照片，不带 Live 角标
- [ ] 调试浮层里音频一行切到 Live 后变 `active=true`，切回照片模式后回到 `active=false`
- [ ] 拍完后 tmp 目录没有残留 `lumen-live-*.mov`（失败路径也要清）

硬件按钮（仅 iPhone 16 及以后）
- [ ] 按侧边相机控制按钮 → 能触发拍摄
- [ ] 保存过程中连按 → 不会重复拍摄

排障
- [ ] 左上角调试浮层实时显示 模式/会话/设备/格式/帧率/曝光/对焦/白平衡/音频/已拍/剩余
- [ ] 点浮层可展开看最近日志；设置页可导出完整日志文件
- [ ] 模式切换条上「视频」显示锁图标，点击提示「视频录制将在 P1b 第二批交付」；「Live」**不带锁**（P1b-1 已交付，可直接拍）

**预期正常现象，不是 bug：**
- 「视频」置灰带锁 → P1b 第二批交付；「Live」现在**已经可用**，不再置灰
- 第一次保存时才弹相册权限 → 故意的，比一上来要完整相册权限的拒绝率低得多
- 浮层里音频一行显示 `active=false` → 照片模式不需要麦克风，正确行为

---

## 四、只能在真机验证的项目

模拟器**全部不可信**：

- 整个相机模块（模拟器无摄像头）
- 点按对焦是否真的生效
- 曝光补偿是否真的改变画面
- 相机控制按钮（`AVCaptureEventInteraction`）
- HEIC 原始数据直存后的画质与 EXIF
- **Live Photo 是否被系统识别成一对**（成对提交只有在真机相册里才能验证）
- **Live Photo 的音轨**（麦克风权限 + 音频会话，模拟器上无从谈起）
- 拍摄功耗与发热

---

## 五、编译状态

**已于 2026-09-16 在 GitHub Actions（macos-15 + Xcode 16 + 无签名）编译通过**——零 error、零代码 warning。
工作流见 `.github/workflows/build.yml`，push 即自动跑，结果页：
`https://github.com/wokenday77/LumenEdit/actions`

首轮编译曾暴露两个真实错误，**均已修复**（留档在此，避免以后重复踩）：

1. **`AVCaptureEventInteraction` / `AVCaptureEvent` 属于 AVKit，不是 AVFoundation** ——
   只 `import AVFoundation` 会报 `cannot find type ... in scope`，已补 `import AVKit`。
   同时确认初始化签名只有 `init(handler:)` 与 `init(primary:secondary:)`，**没有 `primaryAction:` 这个标签**
   （那是 SwiftUI `onCameraCaptureEvent` 的参数名）。
2. **`AVCapturePhotoSettings.uniqueID` 是只读属性**（由系统分配），不能自己赋值 ——
   原来"自生成 ID 写进 settings"的做法编译不过，已改为**运行时认领**：
   第一个回调到达时记下系统 ID，之后校验一致性，迟到回调按 ID 不匹配丢弃。

> ⚠️ **编译通过 ≠ 功能正常。** 相机预览、点按对焦、Live Photo 成对入库、相机控制按钮这些
> **必须真机验证**，见下方验收清单。真机若报错，把报错原文（连同文件名和行号）贴回来即可。

---

## 六、架构约定（后续阶段必须遵守）

### 两条铁律

1. **分层依赖单向向下**：UI 不直接碰 AVFoundation / Photos，全部经服务层。
2. **`EditRecipe` 是唯一真源**（P4 引入）：同一份参数同时驱动相机预设注入、
   修图实时预览、Live Photo 逐帧、视频逐帧——这是「取景器看到什么，导出就是什么」的前提。

### 五条硬性纪律

1. **会话配置顺序不可调整**：
   `beginConfiguration` → `sessionPreset = .inputPriority` → `addInput`
   → 按模式 `addOutput` → `commitConfiguration` → **之后**才写 `activeFormat` / 帧率。
   顺序反了设置会被会话静默重置（默认 preset `.high` 会替你选格式）。
2. **`CaptureDeviceConfigurator` 是唯一允许 `lockForConfiguration()` 的地方**，
   所有硬件参数写回前必须钳制——越界是**抛异常**，不是"被忽略"。
3. **Live Photo 必须成对提交**：照片与配对视频要在**同一个** `PHAssetCreationRequest`
   里添加，拆成两次会让系统认不出一对。
4. **UI 层不实现"点了没反应"**：未实现的功能必须置灰并给出原因。
5. **权限申请按需触发**：相册写入在第一次保存时才申请，麦克风在切到需要录音的模式时才申请。

---

## 七、云端 Mac / 无 Mac 时的编译校验

`.github/workflows/build.yml` 已配好：push 到任意分支就会在 GitHub 的 `macos-15`
runner 上用无签名方式编译一次。**公开仓库分钟数无限**，可以放心频繁提交。

本地想复现同样的命令：

```bash
xcodebuild -project LumenEdit.xcodeproj \
  -scheme LumenEdit \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build
```

> **注意**：云端 Mac 无法 USB 连接你手上的 iPhone，只能做编译校验，**不能真机调试**。

---

## 八、目录结构

```
LumenEdit/
├── project.yml                  # XcodeGen 工程定义（唯一工程真源）
├── .gitignore
├── README.md
├── CONTEXT_HOT.md               # 对话续接摘要（换会话时整份贴上）
├── .github/workflows/build.yml  # 云端编译校验
├── docs/                        # 方案与交接文档（01–07，共 7 篇）
├── tools/
│   ├── make_app_icon.py         # App 图标生成脚本
│   ├── check_prototype.js       # 原型自检（8 组）
│   └── check_swift.js           # Swift 结构自检（4 组）
└── LumenEdit/
    ├── App/                     # 入口、路由、依赖容器
    ├── Resources/               # Info.plist、隐私清单、Assets
    ├── DesignSystem/            # 主题令牌、触感、通用控件
    │   └── Components/
    ├── Core/
    │   ├── Utils/               # 日志、钳制、调试浮层、存储
    │   ├── Permissions/
    │   ├── ImagePipeline/       # CIContext、色彩空间、缩略图
    │   └── MediaIO/             # 相册入库、音频会话
    └── Camera/
        ├── Session/             # 模式、能力、预设、设备配置器、会话控制器
        ├── Output/              # 拍摄结果、照片服务
        ├── Hardware/            # 相机控制按钮
        └── UI/                  # 预览、对焦、曝光面板、ViewModel、主页
```
