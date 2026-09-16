import SwiftUI

// MARK: - 快照模型

/// 浮层里的一行「标签 + 值」
struct DebugHUDLine: Identifiable {
    let id: String
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.id = label
        self.label = label
        self.value = value
    }
}

/// 调试浮层要展示的相机状态。
///
/// 这里刻意只用 String / Int 这种基础类型，不引入任何 AVFoundation 类型——
/// 这样 `Core` 层不需要反过来依赖 `Camera` 层，相机层只负责填充这个结构。
struct CameraDebugSnapshot: Equatable {
    var modeText: String = "—"
    var sessionStateText: String = "—"
    var deviceName: String = "—"
    var formatText: String = "—"
    var frameRateText: String = "—"
    var exposureText: String = "—"
    var focusText: String = "—"
    var whiteBalanceText: String = "—"
    var audioText: String = "—"
    var shutterCountText: String = "0"
    var freeSpaceText: String = "—"
    var lastErrorText: String?

    var lines: [DebugHUDLine] {
        [
            DebugHUDLine("模式", modeText),
            DebugHUDLine("会话", sessionStateText),
            DebugHUDLine("设备", deviceName),
            DebugHUDLine("格式", formatText),
            DebugHUDLine("帧率", frameRateText),
            DebugHUDLine("曝光", exposureText),
            DebugHUDLine("对焦", focusText),
            DebugHUDLine("白平衡", whiteBalanceText),
            DebugHUDLine("音频", audioText),
            DebugHUDLine("已拍", shutterCountText),
            DebugHUDLine("剩余", freeSpaceText),
        ]
    }
}

// MARK: - 浮层视图

/// 屏幕调试图层。
///
/// **为什么需要它**：我们的运行路径是「云端 Mac 编译 → 侧载到 iPhone」，
/// 这条链路上没有 Xcode 调试器、没有实时控制台。相机相关的问题
/// （黑屏、对焦不生效、EXV 不变化、保存失败）只看现象很难定位，
/// 所以把关键状态直接画在屏幕上，再配合日志文件导出。
///
/// 点一下面板可以展开看最近日志。
struct DebugHUDView: View {

    let snapshot: CameraDebugSnapshot
    @ObservedObject var log: DebugLog
    @Binding var isExpanded: Bool

    var body: some View {
        // 收起态只占一个小图标，把取景面积让出来；点一下展开成完整面板。
        // 浮层是"只遮挡不挤压"的，所以收起/展开都不会改变取景器布局。
        if isExpanded {
            expandedPanel
        } else {
            collapsedIcon
        }
    }

    // MARK: - 收起态

    /// 收起态：一个 32×32 的小圆标，**静置时压暗到半透明、融入取景画面**，
    /// 不抢取景的注意力；点一下才展开成完整面板。
    ///
    /// 只压暗底板与文字，错误红点保持醒目——收起状态也不能漏掉问题。
    /// 这里刻意**不用 `.ultraThinMaterial`**：毛玻璃要对每秒 30–60 帧的取景画面
    /// 做实时模糊，有掉帧发热风险（见交接单风险 #7），先做静态半透明。
    private var collapsedIcon: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded = true
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Text("DBG")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.09)))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                    .opacity(0.55)

                if hasError {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 7, height: 7)
                        .offset(x: 2, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasError ? "调试信息（有错误）" : "调试信息")
        .accessibilityHint("点按展开调试浮层")
    }

    // MARK: - 展开态

    /// 展开态：完整状态行 + 最近 8 条日志 + 导出入口
    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("DEBUG")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                Spacer(minLength: 12)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded = false
                    }
                } label: {
                    Text("收起")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.leading, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起调试浮层")
            }

            ForEach(snapshot.lines) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 40, alignment: .leading)
                    Text(line.value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }

            if let error = snapshot.lastErrorText, !error.isEmpty {
                Text("✕ " + error)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.white.opacity(0.25))

            if log.recent.isEmpty {
                Text("（暂无日志）")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(log.recent.suffix(8)) { entry in
                    Text(entry.line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(color(for: entry.level))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ShareLink(item: log.fileURL) {
                Text("导出完整日志")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
            }
            .padding(.top, 2)
        }
        .padding(8)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var hasError: Bool {
        guard let error = snapshot.lastErrorText else { return false }
        return !error.isEmpty
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .white.opacity(0.6)
        case .info: return .white.opacity(0.9)
        case .warn: return .orange
        case .error: return .red
        }
    }
}
