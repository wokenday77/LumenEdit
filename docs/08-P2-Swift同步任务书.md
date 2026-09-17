# 08 · P2 Swift 端同步任务书

> **用途：新会话的启动包。**
> 原型（`prototype/index.html`）UI 骨架已定稿，本文件是把原型界面同步到 Swift 端（`LumenEdit/`）
> 的任务书与拆分计划。
>
> **新会话请连同以下文件一起贴入**：
> - `CONTEXT_HOT.md` —— 原型侧最新状态（CB 维护，含 9 轮迭代记录）
> - `docs/04-交接单.md` —— 工程纪律 8 条
> - `docs/03-布局调整方案.md` —— 布局方案
> - **本文件** —— 同步任务与拆分

---

## 零、分工与两条硬纪律（先读）

| 角色 | 负责 | 提交范围 |
|---|---|---|
| **CB** | `prototype/index.html` 网页原型 | 原型相关 |
| **WB** | Swift 端 `LumenEdit/` + `tools/*.js` | Swift 相关 |

1. ⚠️ **原型是只读参考** —— 同步 Swift 期间**绝不修改** `prototype/` 下任何文件，
   也不要把它的改动提交进来。
2. ⚠️ **禁止 `git add -A`** —— 必须按路径明确列出：
   `git add LumenEdit/Camera/UI/TopBarView.swift`（原型正被 CB 改着，`-A` 会误提交它的半成品）。
   > 教训：提交 `444c43c` 时用了 `-A`，把 CB 改的 `prototype/index.html`（278 行）一起带了进去。

其余工程纪律 8 条见 `docs/04-交接单.md` 第六节（会话配置顺序 / `CaptureDeviceConfigurator`
唯一 lock / Live Photo 成对提交 / 原始字节直存 …）。**Swift 改完必跑**
`node tools/check_swift.js LumenEdit`。

---

## 一、进度基线

| 阶段 | 状态 |
|---|---|
| P1a 照片闭环 | ✅ 已交付 |
| P1b-1 Live Photo | ✅ 已交付 |
| **P1b-2 视频录制** | ✅ 已交付（`MovieCaptureService`，提交 `04b05e8`） |
| **P2 数据层** | ✅ **已完成** —— `LumenEdit/Presets/` 6 个文件 + `tools/check_presets.js`，与原型逐条一致 |
| P2 硬件层 | 🔶 部分 —— 手动对焦、参数能力模型已做；平滑变焦（`Ramp`）待做 |
| **P2 UI 骨架** | 🔶 **进行中** —— 2-1（`logLive`）/ 2-1b（LIVE 角标图标化）已交付；2-2 ~ 2-5 待做 |

---

## 二、13 项模块 → Swift 文件映射

### A 组 · 纯 UI，不碰 `CaptureSessionController`

| # | 模块 | 文件 | 改/新增 |
|---|---|---|---|
| 1 | 顶栏两行 | `Camera/UI/TopBarView.swift` | **新增**（从 `CameraView` 抽出） |
| 2 | 模式条四入口 | `DesignSystem/Components/ModeSelector.swift` | **改**（现有，扩到 4 入口 + 实况同心圆图标） |
| 3 | 焦段条 | `Camera/UI/FocalStripView.swift` | **新增** |
| 4 | 底部图标行 7 项 | `Camera/UI/ToolIconRow.swift` | **新增** |
| 5 | 快门排四件套 + ⤢ 放大 | `Camera/UI/ShutterRowView.swift` | **新增**（`ShutterButton` 从 `CameraView` 迁入） |
| 6 | 场景/风格条 | `Camera/UI/SceneStyleStrip.swift` | **新增**（数据已就绪：`StyleCatalog` / `SceneCatalog`） |
| 7 | 滤镜条 | `Camera/UI/FilterStripView.swift` | **新增**（数据已就绪：`FilterCatalog`） |
| 10 | 功能面板 ⠿ | `Camera/UI/FunctionPanelView.swift` | **新增** |
| 11 | 视频格式芯片 | `Camera/UI/FormatChipView.swift` | **新增** |
| 12 | 设置页 | `Camera/UI/SettingsView.swift` | **新增**（3 页 + 二级页） |

### B 组 · 会碰 `CaptureSessionController`（接线部分）

| # | 模块 | 碰什么 |
|---|---|---|
| 3 | 焦段条**点击** | `applyZoomLocked` → 扩成「按档位切镜头 + 变焦」+ `Ramp` 平滑 |
| 8 | 对焦圆盘 + EV 圆盘 | `setManualFocus(lensPosition:)`（**已就绪**）；EV 走 `setExposureBias` |
| 9 | 三条刻度条（ISO / 快门 / 白平衡） | ISO+快门走 `setExposureModeCustom`；白平衡走 `setWhiteBalanceModeLocked` |
| 11 | 格式**选择器** | 分辨率 / 帧率 → 重设 `activeFormat`（走已有的 `applyFormat`） |
| 13 | 参数导入 | `CapturePreset.init(from: EditRecipe)` —— **等 P4** |

> **界面元素与硬件接线要分层**：先做纯 UI（A 组），接线（B 组）单独一轮。
> 这样 UI 版式可以先用假数据截图验收，不必等硬件。

---

## 三、第 2 批拆分（5 小件）与验证点

| # | 小件 | 内容 | 完成后能验证什么 |
|---|---|---|---|
| **2-1** | `CaptureSessionMode` 加 `logLive` | 枚举加 case（`displayName`「Log 实况」/ `requiresMicrophone: true` / `isImplemented: true`）；**全仓排查所有 `switch` 引用点**，补新分支 | **编译通过**（该枚举被多处 `switch`，漏分支会编译失败）；真机模式条出现第 3 档且可进入 |
| **2-1b** | LIVE 角标图标化（**补充件，2026-09-17 追加**） | 新增共享组件 `DesignSystem/Components/LivePhotoCircleIcon.swift`（外圈 12 点阵 + 中环 + 内点，几何对齐原型 `ICON_LIVE` 的 24 单位 viewBox）；`CameraView.liveBadge` 由「LIVE」文字药丸换成 22×22 黄底同心圆 | 真机截图：**角标外观**与原型一致；模块 #2 把模式条「实况」档文字换成图标时复用同一组件 |
| **2-2** | `TopBarView`（顶栏两行） | 主行 = L/R 电平表 + 模式条 + 三图标；副行 = 影调预览 + 剩余存储。抽成独立 View，`CameraView` 改为引用它 | 真机截图：**顶栏两行版式**与原型并排比对；模式条**居中**（原型第九轮的成果）；存储胶囊显示剩余空间 |
| **2-3** | `FocalStripView`（焦段条） | 4 档药丸（13/24/48/120mm），选中态、刻度标记 | 真机截图：**药丸版式 + 选中态**；点击切换有反馈（接硬件前先 toast） |
| **2-4** | `ToolIconRow`（底部图标行） | 7 项（前置/对焦/白平衡/感光/快门速度/曝光补偿/设置），形态「图标 + 中文小字」 | 真机截图：**7 项排布**；每项点击**必须有反馈**（不允许"点了没反应"，未实现的给 toast 说明） |
| **2-5** | `ShutterRowView`（快门排四件套 + ⤢） | 相册缩略图 · 快门 · 镜头切换 · 风格预览方块；⤢ 放大态 | 真机截图：**四件套版式**；快门**居中**；录制态（红方块）仍正常；⤢ 放大交互 |

**每件的固定验收动作**：`node tools/check_swift.js LumenEdit` 全过 → push →
Mac 侧 `git pull` 编译 + 真机截图 → 据截图迭代。

### 三.1 两条已决事项（2026-09-17）

**① LIVE 角标图标化 → 走 2-1b，不并进 2-2。**（用户决策）

- 拆开的理由：角标与 2-2 要解决的版式问题**正交**。2-2 真正的风险是
  「顶栏两行 + 模式条居中 + 存储胶囊」这一堆版式改动，把图标外观混进去，
  一旦截图对不上，要同时怀疑版式和画法两件事。
- 另有一条硬收益：**同一个图形模式条「实况」档（模块 #2）也要用**。
  做成共享组件后，模块 #2 落地时是一行复用，不维护第二份画法。
- `2-1b` 只动外观，不动位置 —— 位置已由 Mac 侧 `7b67da1` 修到位（见下）。

**② 顶栏两侧等宽预留已由 Mac 侧落地，2-2 在此之上做。**（提交 `7b67da1`）

Mac 侧用真机像素测量发现并修掉了一个我预判方向不对的问题：

| 项 | 实测 |
|---|---|
| 现象 | 模式条四档宽 267.4pt，右端 334.7pt，**与右侧图标组起点 306.7pt 重叠 28pt**，「视频」二字被盖掉一半 |
| 根因 | 顶栏是 `ZStack` 覆盖式（模式条居中、图标组浮在上层），**左侧没有等宽占位** → 模式条盒中心 ≠ 屏中心 |
| 修法 | 改成 `HStack{ 左占位 38 · 模式条 maxWidth:.infinity · 齿轮 }`，中段吃掉 294pt 余量 —— 即原型 `--tb-side-w` 的同款做法 |
| 结果 | 模式条盒中心 201.0pt = 屏中心（屏宽 402pt）；齿轮右端 386pt；零重叠 |

⚠️ **`Theme.Size.topBarSideWidth` 注释里的 267.4 / 370 / 28 是「档位为纯文字 + 内边距 16pt」
这个形态下的实测值，不是常量。** 两件事会让它失效，改完必须重新测量并更新注释：
模块 #2 把「实况」档换成 18pt 图标（该档变窄）、真机换窄屏机型（如 SE 375pt 宽，可用仅 343pt）。


---

## 四、几何规约（重要）

1. **全部相对布局，不写死像素。**
   原型里的 `--fd-size: 246px` / `--fd-center-x: 83.1px` / `--fd-center-y: 662px`
   是**原型侧**的实现手段，Swift 侧**不要照搬数值**。
2. **圆盘圆心对齐「对焦」按钮中心 —— 动态算。**
   原型是从 CSS 推导 `826 −(安全区 18 + 快门 80 + 焦段 44) − 图标行 44/2 = 662`；
   Swift 侧应表达为同样的**相对关系**（用 `GeometryReader` / `alignmentGuide` / `anchorPreference`
   把「对焦」按钮的中心传给圆盘层），而不是写死 662。
3. **圆盘直径的约束**同样相对化：原型口径是"圆盘组（圆盘 + 间距 + 开关行）仍留在屏内"，
   Swift 侧按屏幕可用高度算上限，不写死 246。
4. 尺寸/间距一律走 `Theme.Size`，颜色一律走 `Theme.Palette`。

> ⚠️ 命名空间坑：本项目是 **`Theme.Palette`**（不是 `Theme.Color`）。
> 用某个命名空间前先 `grep -n "enum Palette"` 确认外层容器名 ——
> 曾因凭成员行（`static let canvas = Color.black`）推断而写错 3 处，只有 Mac 编译才发现。

---

## 五、验证方式的现实约束（务必记住）

本机是 **Windows，没有 Xcode、无法编译 Swift、无法截图**。

```
我改 → push → Mac 侧 AI git pull → 编译 + 真机截图 → 我据截图迭代
```

**这个来回是本项目当前最大的瓶颈**，所以：
- **每件做小一点**，宁可多推几次
- 每件只解决一个组件，不夹带
- 每次 push 前跑自检，减少一轮纯编译错误的浪费
