# 16 · B2 ISO / 快门 / 白平衡刻度条方案（模块 #9）

> ⚠️ **2026-09-19 晚修正（必读）**：Mac 复验发现**架构级事实** —— 虚拟多摄不支持全部手动参数
> （SDK `AVCaptureDevice.h:538-541`），且白平衡守卫曾用错探测 API 导致真机 7 连崩。
> 现状：**三条刻度条的手动开关按能力探测置灰**（灰但仍可点，点了给原因），白平衡/对焦守卫已换
> `isLockingWhiteBalanceWithCustomDeviceGainsSupported` / `isLockingFocusWithCustomLensPositionSupported`。
> 物理镜头架构落地后自动开放（能力探测翻转，UI 零改动）—— 施工图见 **`docs/18`**。
> 本文其余内容（几何、交互、数据流、自检）仍然有效。
>
> 状态：**B2b 已交付（2026-09-19）** —— B2a（数据层 + 硬件 API + session 转发 + VM 状态）与
> B2b（刻度条视图 / 图标行高亮 / EV 面板 / 同槽互斥 / 焦段条让位 / 净可见账表）均已完成，
> 分两笔提交、一次 push 给 Mac 验证。5 件拍板见第十一节，实现笔记见第十二 / 十三节。
> **5 件拍板已定**（见第十一节）：净可见分母取**安全区高**；接受**参数排展开时焦段条让位**；
> 切手动档初值取**设备当前值**；拆分方式 **B2-0 并进 B2b、B2a+B2b 分两笔提交一次 push**；
> 触觉与滞后**沿用 `ParameterSlider` 的 0.15s / 0.75**。
> 前置：**B1 过 Mac 真机验证**（`docs/15` 第九节）
> 关联：`docs/08`「B 组执行顺序」B2；`docs/04` 铁律 2（`CaptureDeviceConfigurator` 唯一锁）；
> `docs/11`（参数排与互斥，Backlog ④ 的另一半）；`docs/14`（EV 回写环 —— 本件的回写闸门同款）；
> `docs/15`（B1 —— "能力求交 + 置灰仍可点"，本件复用同一套做法）
> **事实来源**：原型 `prototype/index.html` 读码（只读，未改动）+ 本仓读码核对 + AVFoundation 既有实现。

---

## 零、一句话结论

三条刻度条（ISO / 快门 / 白平衡）**共用一个约 88pt 的面板，一次只显示一条**，由底部图标行三格切换；
**指针固定在中央、刻度条左右滑**；**ISO 与快门共用一个"自动/手动"开关**（硬件约束，见第三节），
白平衡独立一个。切手动走 `setExposureModeCustom` / `setWhiteBalanceModeLocked`。

三件顺带必须做的事：

1. **EV 与"手动 ISO/快门"互斥且必须有痕** —— 现有 `applyExposureBias` 会在手动档下**静默把设备抢回自动档**
   （`CaptureDeviceConfigurator:156-159`），不拦会出现"拖了一下 EV，ISO/快门 设置无声失效"。
2. **补 Backlog ④** —— `collapseOverlays()` + `dismissTransientPopovers()` 都要加进刻度条。
3. **先把"净可见"这笔账定口径**（本文件第三节 2）—— 现有三份文档各算一套账，`docs/11` 的算式**漏了常驻的
   场景·风格条 36pt**；不先把账算准，刻度条区的高度就没有依据。

---

## 一、现状核对（读码结论）

| 事实 | 现状 | 位置 |
|---|---|---|
| 原型三条刻度条 | **一个共用容器 + 单值寄存** `state.paramStrip ∈ {'iso','shutter','wb',null}`，一次只显示一条 | 原型 `L1622`、`toggleStrip` `L3533-3543` |
| 原型刻度条尺寸 | 面板 96pt（`.screen.strip-on .row-params{height:140px}` = 图标行 44 + 96） | 原型 `L407-410` |
| 指针 | **固定在 `calc((100% - 64px)/2)`**，刻度条靠 `translateX` 平移 | 原型 `L558-559`、`L3164-3165` |
| 右端开关 | `.sp-auto` 56pt 宽；**ISO+快门共用 `state.auto.isoShutter`，WB 单独 `state.auto.wb`** | 原型 `L1625`、`L3214-3236` |
| 档位表 | ISO **25 档**（50–12000 等比 1/3 档）、快门 **15 档**（1s–1/12000 整档）、WB **76 档**（2500–10000K 步长 100） | 原型 `L3076`、`L1753-1754`、`L3077` |
| 可视步进 slot | ISO 46 / 快门 56 / WB 26（原型 px） | 原型 `L3086`、`L3097`、`L3107` |
| 数值格式 | ISO → `800`（**无前缀**）/ 快门 → `1/125`（**无 s 后缀**）/ WB → `5600K` | 原型 `L3089`、`L3100`、`L3112` |
| 吸附 | 松手 `Math.round` 吸附最近档；拖动中显示连续值 | 原型 `L3186-3192` |
| 触觉 / 惯性 / 节流 | **原型完全没有** | 原型 `pointermove` `L3203-3210` 无任何节流 |
| `collapseAll` 收几样 | **4 样**：场景·风格 / 滤镜条 / 刻度条区 / EV 圆盘 | 原型 `L1967-1973` |
| 图标行三格行为 | 原型**真展开刻度条**（+ 一条 toast），不是弹提示 | 原型 `L3544-3546` |
| 图标行选中态 | `.icon-item.active{color:#3ddc84}` —— 当前展开的那一格高亮 | 原型 `L1069-1070` |
| **EV 与手动曝光的关系** | **原型未定义**（全文检索无"EV 与手动曝光互斥"之说，各走各的状态） | — |
| **我方** 现有能力模型 | `CameraParameterCapabilities` 已有 `iso` / `exposureSeconds` / `lensPosition` / `zoom` / `whiteBalanceTemperature` 五个 Span | `CaptureDeviceConfigurator:235-264` |
| **我方** 现有硬件写入 | 只有配置期 `applyExposureLocked`（手动档）与运行时 `applyExposureBias`；**没有运行时的手动档入口** | `CaptureDeviceConfigurator:342-360`、`149-162` |
| **我方** 现有 UI | 参数排只有 EV 一条（`ParameterSlider` 复用件）；图标行三格**只弹 toast** | `ExposurePanel.swift`、`CameraViewModel:731-743` |
| **我方** 可复用件 | `ParameterSlider`：吸附 + 居中填充 + **方向闸门** + **换档滞后 0.75** + **触觉节流 0.15s** | `ParameterSlider.swift:38-64` |

> ⚠️ **一个必须记住的既有行为**：`applyExposureBias` 里有一段
> 「处于手动曝光档时顺手切回 `.continuousAutoExposure`」——它的初衷是"避免拖了滑块但画面没反应"，
> 但 B2 之后它的含义变了：**它会在用户手动锁了 ISO/快门 之后被拖 EV 悄悄解除锁定**。
> 第五节按"UI 拦截 + configurator 留痕"两道处理。

---

## 二、① 改哪里

### 新增（3 个）

| # | 文件 | 内容 |
|---|---|---|
| 1 | `LumenEdit/Presets/ParameterStripCatalog.swift` | 三条刻度条的**档位表 + 格式 + slot + 标签档 + WB 预设档**。与 `VideoFormatCatalog` 同族（放 `Presets/`，由 `check_presets.js` 同源校验） |
| 2 | `LumenEdit/Camera/UI/ParameterStripView.swift` | 刻度条组件：**气泡 + 可滑刻度区 + 固定指针 + 右端开关**（一次渲染一条，由 kind 驱动） |
| 3 | `docs/16`（本文件） | 方案落盘 |

### 改（7 处）

| # | 文件 | 改动 |
|---|---|---|
| 4 | `Camera/Session/CaptureDeviceConfigurator.swift` | 新增四个运行时入口：`setManualExposure(iso:seconds:on:)` / `setAutoExposure(on:)` / `setManualWhiteBalance(temperature:tint:on:)` / `setAutoWhiteBalance(on:)`；`applyExposureBias` 的"静默回切自动"改为**留痕**（见五.1） |
| 5 | `Camera/Session/CaptureSessionController.swift` | 四个转发 + 发布 `parameterCapabilities` 与**硬件回读**的手动档状态（见六） |
| 6 | `Camera/UI/CameraViewModel.swift` | `paramStrip` 单值状态、`isoShutterAuto` / `wbAuto`（**派生自硬件，不自己记账**）、拖动编辑态闸门、`stripTapped(_:)`、三个图标入口改真行为、`collapseOverlays()` / `dismissTransientPopovers()` 补齐 |
| 7 | `Camera/UI/CameraView.swift` | 渲染 `ParameterStripView`（与 `ExposurePanel` **同槽互斥**）；参数排展开时**焦段条让位**（见三.2） |
| 8 | `Camera/UI/ExposurePanel.swift` | **删掉那句过时的说明文字**（"ISO / 快门 / 白平衡 手动控制将在 P2 加入"——B2 交付后它变成假话）；手动曝光档下**置灰 + 说明**；面板高 108 → 约 72pt |
| 9 | `Camera/UI/ToolIconRow.swift` | 新增 `activeItem: String?`：**当前展开的那一格高亮**（原型 `.icon-item.active`）。⚠️ 同时把 `isAccent` 从「曝光补偿」拿掉（它的理由是"七项里唯一可用的参数入口"，B2 之后不成立） |
| 10 | `DesignSystem/Theme.swift` | 新令牌（面板高 / 气泡 / 刻度线 / 指针 / 开关 / 三条 slot / 字号） |

### 自检（2 处）

| # | 文件 | 改动 |
|---|---|---|
| 11 | `tools/check_swift.js` | **新增第 12 组**（10 条，见七） |
| 12 | `tools/check_presets.js` | **新增第 6 组**：三条刻度条档位表与原型逐条同源（与第 5 组码率表同款做法） |

---

## 三、② 两态 / 两向

### 1. 面板与三条

```
paramStrip: ParamStripKind?          // .iso / .shutter / .wb / nil —— 单值寄存 = "一次只显示一条"天然成立
```

| 入口 | 行为 |
|---|---|
| 图标行「感光」/「快门速度」/「白平衡」 | 展开对应那一条；**再点同一条 → 收起**；点另一条 → 换条（单值赋值即可） |
| 图标行「曝光补偿」 | 收起刻度条 + 展开 EV 面板（**同槽互斥**，见五.2） |
| 上划 / 下划手势 | 下划一次 `collapseOverlays()` 收干净；上划只负责滤镜条 / 场景·风格（刻度条不参与上划，与原型一致） |
| 点取景器 / 快门 / 模式条 / 顶栏图标 | `dismissTransientPopovers()` 把它收掉（与功能面板、格式选择器同款逐点接线） |

### 2. 每条的"自动 ⇄ 手动"

| | ISO 条 | 快门条 | 白平衡条 |
|---|---|---|---|
| 开关绑定 | **与快门共用 `isoShutterAuto`** | **与 ISO 共用** | 独立 `wbAuto` |
| 硬件事实 | `setExposureModeCustom(duration:iso:)` **必须一次给全两者** —— 锁了 ISO 就得接管曝光时长；反之亦然。所以 UI 上不可能有两个独立开关（原型注释同款，`L1623`、`L3073`） | | `setWhiteBalanceModeLocked(with:)` 与曝光无关，独立 |

**两向语义**

| 方向 | 做什么 |
|---|---|
| 自动 → 手动 | ① 先读设备**当前**值（`device.iso` / `device.exposureDuration` / 当前色温）；② 用它作为手动档初值写一次 `setExposureModeCustom` / `setWhiteBalanceModeLocked`；③ **画面不跳**（初值就是 AE 刚收敛的那个值） |
| 手动 → 自动 | `setAutoExposure(on:)` → `.continuousAutoExposure`；`setAutoWhiteBalance(on:)` → `.continuousAutoWhiteBalance` |
| 自动态下滑动刻度 | **不响应**（原型 `if (stripIsAuto) return`，`L3198`）；气泡显示「自动」，刻度与指针一并置灰 |
| 拖动某条 | **同时写另一条**（ISO 条拖动时把当前快门一起写进去，反之亦然）—— 这是"共用"的另一面，漏了会抛 `partialManualExposure` |

> ⚠️ **3. 与"自动态下刻度不响应"配套的一条**：自动态刻度**不置灰整个面板**，只是
> "划不动 + 指针/数字降透明度"（原型 `.screen.strip-auto` 只改指针与数字颜色）。整块置灰会让人以为坏了。

### 3. 方向 / 手势

刻度条是**横向拖动**：`DragGesture(minimumDistance: 0)` + **方向闸门**（复用 `ParameterSlider` 里那套：
死区 6pt 判一次主轴，全程不改判）。渲染不走 `ScrollView`（会被惯性吃掉手势、也拿不到"松手吸附"）。

- **与整页上划手势的关系**：整页手势的**方向锁**（`CameraView.swipeAxis`，死区 10pt）本来就把横向拖动排除，
  **不需要再加一道编辑态闸门**。这一点与 EV 滑块不同 —— 那里必须加 `isExposureEditing`，是因为
  EV 滑条曾被 `simultaneousGesture` 并发识别后误判成"下划"（`docs/11` 第五节）。刻度条靠方向锁即可，
  **但要写进注释说明"为什么这里不需要第二道闸门"**，免得后人照抄漏了。
- ⚠️ **回写闸门必须加**（与方向锁无关）：硬件值回写 UI 走 `docs/14` 同款两道守卫 —— 拖动期间不回写 +
  只接受"与最后推送值一致"的回写（切模式 / 会话就绪时清空记录）。

---

## 四、③ 内部布局与账

### 1. 面板内部（自上而下）

| 部件 | 规格 | 原型依据 |
|---|---|---|
| 气泡 | 高 22，胶囊，绿底黑字，绿色用 `Theme.Palette.ok`，**固定在指针正上方**（不是跟着刻度跑） | `L573-578` |
| 刻度区 | 可横向拖动；**右侧让出 64pt** 给开关；两端 40pt 渐隐遮罩 | `L539-543` |
| 刻度线 | 普通 `1.5 × 10`（白 34%）、主刻度 `1.5 × 22`（白 82%）、WB 预设档 `1.5 × 22`（**琥珀** = `Theme.Palette.accent`） | `L547-550` |
| 数字 | 10.5pt（白 62%），在刻度线下方 | `L551-555` |
| 指针 | **固定在中线**：三角 6×8 + 竖线 `1.5pt`，绿。⚠️ **原型有两个不同的绿**（指针 `#3ddc84`、开关 `#30d158`）→ 我方**统一到 `Theme.Palette.ok`**，理由：肉眼不可辨的差值不值得新增两个色令牌（与本项目既有取舍一致） | `L558-569`、`L827` |
| 右端开关 | 56pt 宽：开关 47×29（开 = `Theme.Palette.ok`）+ 标签「自动」10pt（**标签不跟开关变色**） | `L581-586`、`L585` |

**数值格式**（与原型逐字对齐）：ISO → `800`；快门 → `1/125`（最慢档是 `1`）；白平衡 → `5600K`。

### 2. ⚠️ 高度上限：先把"净可见"这笔账定口径（本件的第 0 步）

**问题**：现有三份文档各用一套口径，且 `docs/11` 的算式**漏了常驻的场景·风格条**。

现状读码（`CameraView`）：

```
bottomArea = VStack(spacing: 16) {
    [滤镜条 144 或 0]
    场景·风格条 36（折叠）/ 147（展开）      ← ⚠️ 无条件渲染，一直占一行
    [图标行 44 / 参数排 H]                  ← ⤢ 放大态整行让位
    [焦段条 44]                             ← 场景·风格或滤镜条展开时让位
    快门排 80
}
.padding(.bottom, 10)
```

`docs/11` 写的「底栏栈 210 = 10 + 80 + 16 + 44 + 16 + 44」= 快门排 + 焦段条 + 图标行 + 底内边距，
**没有那 36 + 16 = 52pt 的场景·风格条**。所以 `docs/11` 的 57% / 43% 两个数都与真实值不符：

| 状态 | 真实底栏栈（874 机型） | 净可见（分母 = 整屏 874） | 净可见（分母 = 安全区 778） | `docs/11` 记的 |
|---|---|---|---|---|
| 常态（参数排收起） | 262 | 450 → **51.5%** | 450 → **57.8%** | 57% |
| 参数排展开（EV 108pt） | 386 | 326 → **37.3%** | 326 → **41.9%** | 43% |

> `docs/11` 那个 57% **恰好**等于"分母取整屏 + 算式漏掉 36pt"两个偏差的合成 —— 结论（≥50%）碰巧还成立，
> 所以真机验收（只查"≥50%"）没暴露它。

**所以**：刻度条区的高度**现在没有可靠依据**。本方案把它列为 **B2 第 0 步（前置件）**：

1. 把底栈每一行的高度与行距**全部从 `Theme` 真读**，写进自检第 12 组，打印
   **4 机型（874 / 852 / 844 / 667）× 全部浮层组合**的实测账；
2. 定死分母口径 = **安全区高**（✅ **2026-09-19 用户拍板**。理由：语义正确 —— 用户看到的可见范围
   才是基准；取景器本身就住在安全区内，拿整屏高当分母等于把状态栏与 Home 指示条算进"可见取景"）；
3. 据此定死刻度条区的高度上限，再回头核对既有各态（场景·风格展开 / 滤镜条展开）是否真的守住 50%。

**定案值与账**（口径 = **安全区高**，用户拍板 ①；**全部由自检第 12 组⑩ 逐机型复算**）

- **刻度条区 84pt**（原型 96；**初稿 88 → 压到 84**：88 时 844 机型只剩 50.3% ≈ **2pt 余量**，
  而本项目恰在 2pt 余量上吃过亏（`docs/11`）—— 压到 84 换 **6pt 余量**）
- **EV 面板 72pt**（删掉那句过时说明后的净高 = 标题行 26 + 间距 6 + 轨道 20 + 上下内边距 20；
  手动档多一行说明 → 84pt。**那句说明必须 ≤ 20 字**，否则折两行又把面板顶高 12pt —— ⑩ 会核）
- **参数排（EV 面板 / 刻度条区）展开时焦段条让位**（✅ 拍板 ② 已落地）

| 状态 | 底栏块 | 874 | 852 | 844 | 归属 |
|---|---|---|---|---|---|
| 常态 | 262 | 57.8% | 56.6% | 56.1% | 既有 |
| **刻度条展开**（焦段条让位） | 302 | **52.7%** | **51.3%** | **50.8%** | **B2** |
| **EV 面板展开 · 自动档** | 290 | **54.2%** | **52.9%** | **52.4%** | **B2** |
| **EV 面板展开 · 手动档**（多一行说明） | 302 | **52.7%** | **51.3%** | **50.8%** | **B2** |
| 场景·风格展开 | 313 | 51.3% | **49.9%** ⚠️ | **49.3%** ⚠️ | 既有 |
| 滤镜条展开 | 362 | **45.0%** ⚠️ | **43.4%** ⚠️ | **42.8%** ⚠️ | 既有 |

> 底栏块 = 底内边距 10 + Σ行高 + 行距 16 × 间隙数；净可见 = 安全区高 − (上内边距 10 + 顶栏 56) − 底栏块。
>
> ⚠️ **本表自纠过一次**：本节初稿那些百分比（60.7 / 59.5 / 59.1 …）**漏减了顶栏块 66pt**，
> 所以每项都乐观约 8.5pp。⑩ 已经把这件事做成"读令牌 + 逐机型复算"，**数字以自检输出为准**。
>
> 🔴 **两个既有态在"安全区高"口径下低于 50%**（⑩ 会打印一行 `注意`，但**不 FAIL** —— 不在 B2 范围）：
> **场景·风格展开**（844 上 49.3%）与**滤镜条展开**（844 上 42.8%）。
> 这两条是 A 组就验过的版式，要修得动 147 / 144 这两个既有高度（还牵着 `147.0 = 147.0` 那条恒等式）
> —— **需要单独拍板**，本件不做。

**让步顺序（若定案后 88pt 仍不够）**：
① 焦段条让位（本方案已含）→ ② 刻度条区继续压（下限约 72pt，再低气泡与数字要打架）→
③ 才考虑动快门排 / 图标行（这两个都是"不能动"的，只能作为最后手段并由用户拍板）。

---

## 五、④ 与相邻组件的互斥 / 耦合

### 1. 🔴 EV 与"手动 ISO/快门"的硬冲突（本件最要紧的一处）

**事实链**：
- `setExposureTargetBias` **只在自动曝光档生效**；`setExposureModeCustom` 之后系统**忽略** EV。
- 现有 `applyExposureBias` 的第一段就是「手动档 → 顺手切回 `.continuousAutoExposure`」（`156-159`）。
- ⇒ B2 之后：用户手动锁了 ISO 3200 / 1/500，然后手指碰了一下 EV 滑块 → **设备静默回到自动档，
  ISO/快门 设置当场作废，且没有任何提示**。这比"点了没反应"更糟：它**静默改掉了别处设置**。

**处理（三道）**：

| # | 位置 | 做法 |
|---|---|---|
| ① | UI（主） | 手动曝光档下**EV 面板整块禁用**（`isEnabled: false` + 说明文字）+ 点「曝光补偿」时 toast：`手动 ISO/快门 档下 EV 不生效 —— 先切回自动 ` |
| ② | VM | `exposureEditingChanged` 里加守卫：手动档下**不推硬件**（拦住任何漏网的调用路径） |
| ③ | Configurator（兜底） | 那段"顺手切回自动"**保留**（它仍是"避免拖了没反应"的最后防线），但改成**打一条 `warn` 日志**：真被触发时留痕，可查 |

### 2. 互斥矩阵

| 触发方 | 收起谁 | 依据 |
|---|---|---|
| 展开刻度条 | 场景·风格 / 滤镜条 / **参数排（EV）** | 原型 `toggleStrip` `L3535` |
| 展开场景·风格（`toggleSceneStyle`） | 滤镜条 / 参数排 / **刻度条** | 原型 `setSS` `L1959` |
| 上划呼出滤镜条（`swiped(up:)`） | 场景·风格 / 参数排 / **刻度条** | 原型 `setFilter` `L1964` |
| 点「曝光补偿」 | 刻度条（+ 既有两向） | 原型 `iconEV` 先 `collapseAll()` 再开 EV `L3548-3554` |
| 开功能面板 / 格式选择器 | 走 `dismissTransientPopovers()` → 顺带收刻度条 | 我方统一入口（原型无此互斥，见偏离点 ④） |
| 下划 `collapseOverlays()` | **一次收干净**：滤镜条 / 场景·风格 / 参数排 / **刻度条** | Backlog ④ 的正解，原型 `collapseAll` 收 4 样 |

**同槽互斥（本件新增的一条结构性约束）**：`ExposurePanel` 与 `ParameterStripView` 占的是**同一个位置**
（图标行之下那一行）。所以两者**必须同时最多一个可见** —— 这既是原型的语义（EV 圆盘与刻度条互斥），
也是几何上的硬要求（两个都展开，底栏栈会到 408pt）。

> ⚠️ `ExposurePanel` 与 `ParameterStripView` 的渲染要用**同一个 `if/else` 分支**，不要写两个独立 `if` ——
> 两个独立 `if` 在状态竞争下会同时为真（本项目在浮层互斥上翻过车）。

---

## 六、⑤ 状态与持久化

| 状态 | 落盘？ | 理由 |
|---|---|---|
| `paramStrip`（当前展开哪条） | ❌ 不落盘 | 临时浮层状态（原型 `state.paramStrip` 是会话态，不进「保留设置」） |
| `isoShutterAuto` / `wbAuto` | ❌ **不落盘，也不自己记账** —— **从硬件回读** | 见下 |
| 手动档的 ISO / 快门 / 色温数值 | ❌ 不落盘（同上，回读） | 见下 |

**为什么"从硬件回读"而不是本地记账**（这是本方案里最重要的一条架构决定）：

- 设备的 `exposureMode` / `whiteBalanceMode` / `iso` / `exposureDuration` **是同一个 device 实例上的真值**；
  切模式（照片↔视频）只重建 output，input 与 device 不变 → **手动档状态会活下来**。
  本地记账必然出现"UI 说自动、设备是手动"的不一致（就是"点了没反应"那一类）。
- 这正是 `docs/14` 那条教训的推广：**UI 的"硬件参数态"只能由硬件单向回写，不能自己记账**。
  做法的形状也一样：`CaptureSessionController` 发布、VM 订阅、**拖动期间不回写 + 只接受最后推送值**。
- 因此：**冷启动一律自动档**（设备本来也是），不落盘也就不会出现"冷启动把 ISO 3200 推回硬件、
  画面先黑一下"的坏体验。与 EV 落盘的差别：EV 是"用户在自动档下常用的补偿值"，
  手动 ISO/快门是"临时接管"，不该跨启动活下来。

**回写闸门**（`docs/14` 同款两道，逐条对得上）：

1. 拖动期间 `guard !isStripEditing` 不回写；
2. 只接受与 `lastPushedManualExposure` / `lastPushedWhiteBalance` 一致的回写（丢弃队列里积压的旧值）；
3. 切模式 / 会话就绪时清空那两个记录（那时硬件值来自设备，不是我们推的）。

---

## 七、⑥ 自检增强

### `tools/check_swift.js` 第 12 组（10 条）

| # | 检查 | 为什么 |
|---|---|---|
| ① | 三条刻度条**单值寄存**（`paramStrip: ParamStripKind?`，不是三个 Bool / 不是数组） | "一次只显示一条"是本件的核心不变量，用类型保证 |
| ② | `setExposureModeCustom` / `setWhiteBalanceModeLocked` **只出现在 `CaptureDeviceConfigurator`** | 铁律 2：唯一锁的地方 |
| ③ | ISO 与快门**必须在同一次 `setExposureModeCustom` 调用里**给全（`duration:` 与 `iso:` 都在） | 只锁一半会抛 `partialManualExposure`（既有错误枚举） |
| ④ | 写入前 clamp：ISO 落 `format.minISO...maxISO`、时长落 `format.minExposureDuration...maxExposureDuration`、WB 增益走既有 `normalize(_:for:)` | 越界是**抛异常**，不是被忽略 |
| ⑤ | `collapseOverlays()` 必须收刻度条 **且** `dismissTransientPopovers()` 也必须收它 | Backlog ④ 的两半，少一处就会"下划收不干净" |
| ⑥ | `ExposurePanel` 与 `ParameterStripView` 必须**互斥**（`else` 分支，不是两个独立 `if`） | 两个独立 `if` 会同时为真 |
| ⑦ | 手动曝光档下 EV 必须被拦（VM 里存在"手动档不推 EV"的守卫 + configurator 的自动回切**带 warn 日志**） | 防"拖 EV 静默解掉 ISO/快门 锁定" |
| ⑧ | **量级守卫**：刻度条的触觉节流 ≥ 0.1s、换档滞后 ≥ 0.7 档 | 沿用 `docs/11` 第七节的判据（"机制在但量太小等于没做"） |
| ⑨ | 刻度条**不落盘**（全仓不存在 `lumen.camera.strip.` 键） | 防后人手滑加上（本节第六节的架构决定） |
| ⑩ | 净可见：面板高度从 `Theme` 真读，对 4 机型 × 各浮层组合复算，并守"参数排展开时焦段条必须让位" | 第三节 2 的第 0 步成果固化 |

### `tools/check_presets.js` 第 6 组

三条档位表与原型逐条同源 + 结构断言：ISO 25 档严格递增、快门 15 档严格递减（1 → 1/12000）、
WB 76 档 = 2500…10000 步长 100、slot 三值与原型一致、WB 预设档 5 个。

---

## 八、刻意偏离原型的点 + 理由

| # | 偏离 | 理由 |
|---|---|---|
| ① | 刻度条区 **96 → 88pt** | 原型的 96 是它自己的屏高模型下的值；我方 4 机型逐档复算后 88 才是能同时守住 50% 的上限（见三.2，定案前为暂定值） |
| ② | **参数排展开时焦段条让位** | 原型只在 `.ss-on / .filter-on` 隐藏焦段条。不让位时任何高度都过不了 50%（底栏栈会到 278+H） |
| ③ | 切手动档的初值取**设备当前值**，不用原型的常量 `800` / `1/125` / `5600K` | 原型是纯占位（它没有硬件）。真机上用常量会让画面在"切手动"的瞬间**跳一下** —— 系统相机都是"接着当前值往下走" |
| ④ | 刻度条展开时**收掉功能面板 / 格式选择器** | 原型无此互斥（`toggleStrip` 不碰 `fnOpen`）。但原型的面板是**盖住底栏的模态浮层**、与底栈行天然不共存；我方走 `dismissTransientPopovers()` 是与其它图标入口的统一惯例，不做会出现"面板盖着刻度条" |
| ⑤ | **EV 与手动曝光互斥且有痕** | 原型**未定义**（全文无此说明）。依据是 AVFoundation 事实 + 我方 `applyExposureBias` 的既有"静默回切" —— 不管必然出现"设置无声失效" |
| ⑥ | 档位表与**设备能力求交**，越界档位置灰（灰但仍可点） | 原型是纯数组。真机上 `minISO/maxISO` 与 `min/maxExposureDuration` 随 `activeFormat` 变（1s 长曝光在多数 format 下不可用）→ 不置灰就是"点了没反应"。复用 B1 的 `unavailableFocalIds` 同一套做法 |
| ⑦ | 加**触觉 + 换档滞后**（原型完全没有） | 原型 §4 明确"未找到"节流/惯性。32 档的 WB 条没有滞后必然"边界处连响"（`docs/11` 第七节踩过同一坑）。直接沿用 `ParameterSlider` 的 0.75 / 0.15s，不另定一套 |
| ⑧ | 指针绿与开关绿**统一到一个令牌** | 原型是两个硬编码绿（`#3ddc84` / `#30d158`），肉眼不可辨 |
| ⑨ | 图标行「曝光补偿」的 accent **拿掉**，改为"当前展开的那一格高亮" | 原型的 `.icon-item.active` 就是这个语义；accent 的原始理由是"七项里唯一可用的参数入口"，B2 之后不成立 |

---

## 九、Mac 验收清单（真机）

**面板与切换**
1. 点「感光」→ 刻度条升起、那一格图标高亮；再点同一条 → 收起；点「白平衡」→ **换条不是并存**
2. 点「曝光补偿」→ 刻度条收起、EV 面板升起（**同槽**，不叠加）；反向亦然
3. 下划一次 → 滤镜条 / 场景·风格 / 刻度条 / 参数排**一次收干净**；点取景器同样收干净

**刻度条手感**
4. 指针**固定在中央不动**，手指横滑时刻度条跟着走；松手**吸附**到最近档（不落在两档之间）
5. 慢拖逐档有"咔"、可数；快扫一段只响 2~3 声（节流生效）；停在两档边界**不连响**
6. 竖向落手 / 上划起手在刻度条上 → **不改值**（方向闸门）

**硬件与画面**
7. 自动态：气泡显示「自动」、刻度划不动；切手动 → **画面不跳**（初值 = 当前 AE 值）
8. ISO 条取 `100` / `3200` → 画面明显变亮/变暗；快门条取 `1/1000` → 明显变暗、运动更凝固
9. 手动 ISo 档下拖快门条 → **ISO 值保持不动**（两者一起写，不能互相顶掉）
10. 白平衡条取 `3000K` → 画面明显偏暖；取 `7000K` → 明显偏冷；`5200K` / `6000K` 等预设档位有琥珀刻度线
11. 切回自动 → 画面恢复 AE/AWB；**再展开刻度条，气泡回到「自动」**
12. 🔴 **手动 ISO/快门 档下点「曝光补偿」** → 必须给 toast 说明"EV 不生效"，**绝不能静默把设备切回自动**
13. 切模式（照片→视频→照片）后回来 → 刻度条状态与设备**一致**（UI 不撒谎）
14. 录制中切档位 → 不崩；回放能看到参数变化
15. 冷启动 → 一律自动档（不残留上次的手动值）
16. 净可见：刻度条展开时取景器可见高度目测不小于常态太多；**并核对第 0 步账表的实测值**

**图标与文案**
17. 三条的数值格式：ISO `800`（无前缀）、快门 `1/125`（无 `s`）、WB `5600K`
18. 设备不支持某个档位（若 `minISO` 高于表内最低档）→ **置灰但仍可点**，点了给原因
19. HUD 里曝光行能显示 `M ISOxxxx 1/xxx`（`CaptureDeviceState.exposureText` 已有该分支）

---

## 十、边界（不做）/ 拆分 / 风险

### 不做
- 手动对焦圆盘、EV 圆盘（模块 #8，下一件；**圆盘的编辑态要接同款闸门**）
- 曝光锁定 AE-L、白平衡**色调 tint** 单独一根条（只做色温；tint 取设备当前值跟随）
- 捏合连续变焦、长曝光上限（夜景模式）
- 参数导入（模块 #13，**等 P4**）

### 拆分建议（请拍板）

| 件 | 内容 | 能验证什么 |
|---|---|---|
| **B2-0** | **净可见口径定案 + 账表**（纯文档 + 自检骨架） | 刻度条区高度上限有依据；顺带核对既有各态是否真守住 50% |
| **B2a** | 数据层（档位表）+ 能力求交 + 四个硬件 API + session 转发 + VM 状态 | **只有日志与 HUD 可验证**（没有 UI 入口） |
| **B2b** | `ParameterStripView` + 图标行接线 + 同槽互斥 + `collapseOverlays`/`dismissTransientPopovers` 补齐 + 自检第 12 组 | 真机截图 / 手感 / 视觉 |

> **建议 B2a 与 B2b 分成两笔提交、但一次 push 给 Mac 验证** —— 理由是 B2a 单独交付时**没有 UI 入口，
> Mac 侧只能靠 HUD 与日志间接验证**（会比一轮常规验证更费事）。若用户希望严格"一件一验"，
> 也可以 B2a 先推一笔（用 HUD 的 `M ISO…` 分支验写入），B2b 再推一笔。

### 风险与回退

| 风险 | 处理 / 回退 |
|---|---|
| 拖动每档就写一次 `setExposureModeCustom`，比 `setExposureTargetBias` 重 → 可能卡顿 | 现状 EV 就是每档一次；真机若卡，改为**松手才写 + 拖动中只更新气泡**（一处开关） |
| 档位表与设备能力求交后档数太少（某些 format 的 `minISO` 很高） | 求交后若少于 2 档 → 该条**整条置灰** + toast 说明"当前采集格式不支持手动该参数"（诚实边界） |
| WB 色温 ↔ 增益映射在极端值上被 clamp | 已有 `normalize(_:for:)`；toast 报**实际生效**的色温（`temperatureAndTintValues` 反查），不报请求值 |
| 手动档与 EV 的互斥被绕过 | 三道防线（UI 禁用 / VM 守卫 / configurator warn 留痕），自检第 12 组 ⑦ 条守着 |
| 高度定案后 88pt 仍不够 | 按四.2 的让步顺序；实在不行由用户拍板是否接受某个态 < 50% |
| `ramp` 那类"签名靠猜"的 API | 本件用的四个方法签名都已在既有代码里出现过（`setExposureModeCustom` / `setWhiteBalanceModeLocked` / `exposureMode` / `whiteBalanceMode`），**没有新签名风险** |

---

## 十一、5 件拍板结论（2026-09-19 用户拍板 · 已定）

| # | 议题 | **结论** | 落地影响 |
|---|---|---|---|
| ① | 净可见分母口径 | **取「安全区高」** —— 语义正确：用户看到的可见范围才是基准；取景器本身就住在安全区内，拿整屏高当分母等于把状态栏与 Home 指示条算成"可见取景" | 三机型余量均 ≥5pp（见三.2）→ **第 0 步从阻塞项降级为复核项**，本件可一次做完 |
| ② | 参数排展开时焦段条让位 | **接受**（偏离原型；不让位任何高度都过不了 50%） | `CameraView` 里焦段条的显示条件由 2 个扩到 3 个（`\|\| 参数排展开`），并入既有的"扩展浮层展开 → 焦段条让位"统一规则 |
| ③ | 切手动档的初值 | **取设备当前值** —— 避免切档瞬间画面跳 | `setManualExposure` 前先读 `device.iso` / `device.exposureDuration`；白平衡读 `temperatureAndTintValues(for: deviceWhiteBalanceGains)` |
| ④ | 拆分方式 | **B2-0 并进 B2b；B2a + B2b 分两笔提交、一次 push** | B2a = 数据层 + 能力求交 + 四个硬件 API + session 转发 + VM 状态；B2b = UI + 图标行接线 + 互斥 + 自检第 12 组（含净可见账表） |
| ⑤ | 触觉与换档滞后 | **沿用 `ParameterSlider` 的 `0.15s` / `0.75`** —— 已验证过的值，不折腾 | 刻度条复用同一套常量；自检第 12 组⑧条守住量级 |

**仍然开着的（不影响开工）**：

- 前置模式下焦段条是**整条隐藏**还是**保留 + 全部置灰** → 留给"接前置"那件拍板（见 `docs/15` 第四节末）
- 拖动时"每档写一次硬件"若真机卡顿 → 退化为"松手才写 + 拖动中只更新气泡"（见第十节风险表）

---

## 十二、实现笔记（B2a 已交付 · 2026-09-19）

### 交付了什么

| 层 | 文件 | 内容 |
|---|---|---|
| 数据 | **新增** `Presets/ParameterStripCatalog.swift` | `ParameterStripKind`（iso / shutter / whiteBalance）+ `ParameterStripStep` + 三张档位表（ISO 25 / 快门 15 / 白平衡 76）+ 数值格式 + slot 46/56/26 + 标签档 + WB 预设档 + 默认值 + **各条的求交容差** + `nearestStep` |
| 能力 | `Camera/Session/CaptureCapabilities.swift` | `availableRange(for:on:)`（ISO → `minISO…maxISO`；快门 → `min…maxExposureDuration`；WB → 标称域不设限）+ `isStripValueAvailable` + `unavailableStripValues` + `stripSummary`（日志一行） |
| 硬件 | `Camera/Session/CaptureDeviceConfigurator.swift` | 4 个运行时入口 `setManualExposure(iso:seconds:)` / `setAutoExposure` / `setManualWhiteBalance(temperature:tint:)` / `setAutoWhiteBalance`；2 个回读 `manualExposure(of:)` / `manualWhiteBalance(of:)` + `currentTint` / `currentTemperature`；新错误 case `unsupportedManualExposure`；**`applyExposureBias` 的"手动档回切自动"改为留痕**（warn） |
| 会话 | `Camera/Session/CaptureSessionController.swift` | 4 个转发 + `publishManualState(_:)`（一次刷新：手动档真值 / 当前值 / 刻度条可用域）+ 2 个新 `@Published`（含 `currentExposure` / `currentWhiteBalanceKelvin`）；**7 处调用点**：4 个写入后 · `setExposureBias`（可能回切自动）· `focus(atDevicePoint:)`（**点按对焦会把曝光打回自动**）· `applyPreset` · 会话就绪 · 切模式 |
| VM | `Camera/UI/CameraViewModel.swift` | `paramStrip`（单值寄存）+ 派生 `isISOShutterAuto` / `isWhiteBalanceAuto` + `stripDisplayValue` / `unavailableStripValues(for:)` + `stripTapped` / `stripAutoToggled` / `stripValueChanged` + **`collapseOverlays()` / `dismissTransientPopovers()` 补刻度条（Backlog ④ 关闭）** + **手动档下 EV 三道拦** |

### ⚠️ 一处**偏离方案**的实现改进（请知悉）

方案第六节原写"刻度条要接与 `docs/14` **同款**的回写闸门（拖动期不回写 + 只接受最后推送值）"。
实现时改成更省的结构，**那道闸门不需要存在**：

```
显示值 = 拖动期 → 本地草稿（跟手）
         其余时刻 → 硬件真值（session.manualExposure / manualWhiteBalance）
```

于是"本地值"与"硬件值"不会同时存在两份 → `docs/14` 那个环路**结构性不可能发生**（少一套状态 = 少一类 bug）。
副作用：`isStripEditing` 这个闸门也不再需要；拖动草稿只在拖动期存在，松手即清。

另外，EV 与手动档的互斥做成了**三道**（方案里是两道）：
① 点「曝光补偿」时若在手动档 → toast 说明（不做"点了没反应"）；② VM 的 `exposureEditingChanged` 守卫；
③ configurator 的"回切自动"保留为最后防线但**打 warn 留痕**。

### 自检落点（本项目"每件都要有守卫"）

| 检查 | 落点 | 条数 |
|---|---|---|
| 参数刻度条（B2a 那半） | `check_swift.js` **第 12 组** | **8 条**：单值寄存 / 三格接线 / 回读不记账 / 成对写 / 三处 clamp / 唯一入口 / Backlog ④ 两半 / EV 三道 / 不落盘 / 草稿+硬件真值 |
| 三张表与原型同源 | `check_presets.js` **第 6 组** | **9 条**：ISO 25 档 / 快门 15 值 / 快门 15 标签 / WB 生成规则 76 档 / slot 46-56-26 / ISO 标签档 7 / WB 预设档 5 / WB 标签档 15 / 默认值 |
| 变异测试 | `.workbuddy/mutation-test-b1.py` | **29/29 触发**（B2a 新增 M23~M29：paramStrip 改非可选 / 拆散成对写 / 去 clamp / 去 EV 闸门 / collapseOverlays 不收刻度条 / 假派生 / 只取草稿） |

> 变异测试这一轮又抓出**两条守卫太松**：③（成对写）和 ④（三处 clamp）原本是**全文匹配**，
> 而项目里还有一条**预设路径**（`applyExposureLocked`）也调 `setExposureModeCustom(duration:iso:)`、
> 也有同样名字的 `safeISO` —— 于是"手动方法里把 `iso:` 拆掉"仍能被另一处满足，守卫形同虚设。
> 已改成**限定在 `setManualExposure` / `setManualWhiteBalance` 的方法体内**匹配。

### B2b 需要的东西（接口已就位）

- 读：`viewModel.paramStrip` / `stripDisplayValue(_:)` / `unavailableStripValues(for:)` / `isISOShutterAuto` / `isWhiteBalanceAuto`
- 写：`stripTapped(_:)` / `stripAutoToggled(_:)` / `stripValueChanged(_:value:isEditing:)` / `dismissParamStripIfNeeded()`
- 数据：`ParameterStripCatalog.steps(for:)` · `slot(for:)` · `label(for:value:)` · `tolerance(for:)`
- 还缺（B2b 做）：`Theme` 令牌（面板高 88 / 气泡 / 刻度线 / 指针 / 开关）、`ParameterStripView`、`ToolIconRow` 的 active 态、
  `ExposurePanel` 删过时文案 + 手动档禁用 + 面板高 108 → 72、`CameraView` 同槽互斥 + 焦段条让位、自检第 12 组⑥⑩（净可见账表）

### 🔴 真机冷启动崩溃（Mac 侧 2026-09-19 抓到 · 已修）—— 本仓第一例 ObjC 异常 abort

**崩溃栈**：

```
objc_exception_throw
  -[AVCaptureFigVideoDevice temperatureAndTintValuesForDeviceWhiteBalanceGains:]  ← 抛
  CaptureDeviceConfigurator.currentTemperature(of:)      （:363-365）
  CaptureSessionController.publishManualState(_:)        （:446）
  CaptureSessionController.startInternal()               （:728-730）
```

**根因链**：`startInternal()` 在 `session.startRunning()`（异步）之后立刻调 `publishManualState` →
此刻设备还没跑起来、白平衡尚未初始化，`deviceWhiteBalanceGains` 是无效值 →
`currentTemperature(of:)` 拿着无效 gains 调 `temperatureAndTintValues(for:)` →
该 API 对无效增益抛 `NSInvalidArgumentException` → **Swift 拦不住 ObjC 异常** → 全进程 abort。
触发条件：**装后首启 / 重启后首启**这种冷白平衡态。

**修法**：
1. **首选（已做）**：抽共享私有助手 `temperatureAndTintValues(of:)`，**转换前先校验增益**
   （三个分量都 finite 且在 `1.0 … device.maxWhiteBalanceGain`）→ 无效返回 `nil`，**不调 API**；
   三个调用点（`manualWhiteBalance(of:)` / `currentTint(of:)` / `currentTemperature(of:)`）全部走它。
2. **同类隐患一起修**：`currentTint` 无效时兜底 **0**（传回去等价于"色调不动"）；
   `currentTemperature` 无效时兜底 **5600K**（与 `ParameterStripCatalog` 默认值同源）。
3. **可选加固（已做）**：`publishManualState` 发现增益无效就记一笔
   （`needsColdWhiteBalanceRefresh`），由每秒的快照轮询在**增益就绪后补发一次**——
   免得 UI 一直停在兜底值 5600K 上。

**两条通用教训**（已记长期记忆）：**Swift catch 不到 ObjC 异常，只能在入参上防**；
**读硬件状态的 API 都要问一句"它此刻处于有效状态吗"**（`startRunning` 是异步的，
"调用了"≠"已经就绪"）。

---

## 十三、B2b 交付记录（2026-09-19 · UI）

| 层 | 文件 | 内容 |
|---|---|---|
| 令牌 | `DesignSystem/Theme.swift` | **Palette** +9（`stripTick` / `stripTickMajor` / `stripTickPreset` / `stripNumber` / `stripInactive` / `stripAccent`（= `ok`，指针+气泡+开关统一）/ `stripBubbleText` / `stripSwitchOff` / `stripPanelBottom`）；**Size** +18（面板高 84 / 气泡 / 刻度线 / 指针 / 开关 / 两端遮罩 / 方向闸门死区 …） |
| 视图 | **新增** `Camera/UI/ParameterStripView.swift` | `ParameterStripGeometry`（**纯算术**，⑩ 照它复算）+ 刻度条本体：气泡 / 固定指针（`DownTriangle` 自绘，不依赖 SF Symbol）/ 可拖刻度区（两端渐隐 mask）/ 右端开关 |
| 图标行 | `Camera/UI/ToolIconRow.swift` | 新增 `ToolIconRowItem` 枚举 + `activeItem` 高亮（原型 `.icon-item.active`，用**原型那个绿** `Palette.ok`）+ `.isSelected` 无障碍标记；**旧 `isAccent` 退场**（"唯一可用参数入口"的理由 B2 后不成立） |
| EV 面板 | `Camera/UI/ExposurePanel.swift` | 删过时说明（108 → **72pt**）+ 手动档**整块禁用 + 一句话说明**（≤20 字，⑩ 核长度） |
| 接线 | `Camera/UI/CameraView.swift` | 图标行传 `activeToolRowItem`；**参数排与刻度条 `if / else if` 同槽互斥**；**焦段条在参数排/刻度条展开时让位**；`paramStrip` 过渡动画 |

**自检落点**：第 12 组 8 → **14 条**（新增 ⑥ 同槽互斥 / ⑩ 净可见账表 / ⑮ 图标行高亮态）；
**变异测试 34/34 触发**（新增 M30 拆成两个独立 if / M31 面板加高破账 / M32 说明文案写太长 /
M33 拿掉高亮态 / M34 忘了传 activeItem）。

> ⚠️ 变异测试这一轮又抓到**一条判定窗口太窄**（M30）：⑩ 前面那条"不是 else if"的判定窗口
> 只有 1000 字符，装不下 `ExposurePanel(…)` 那一整块（含注释约 1.6k），
> 于是 FAIL 报了但**文案指不到根因**（报"不是 else if"而不是"两个独立 if"）。窗口已放宽到 2500。

### B2b 之后仍开着的

- **既有两个态低于 50%**（场景·风格展开 49.3% / 滤镜条展开 42.8%，844 上）—— 见第三.2 节末，需单独拍板
- 拖动时"每档写一次硬件"若真机卡顿 → 退化为"松手才写 + 拖动中只更新气泡"（第十节风险表）
- `#8` 的 EV 圆盘落地时，`collapseOverlays()` 还要再加它一项