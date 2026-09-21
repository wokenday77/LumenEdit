import AVFoundation
import Foundation

/// **一次性验收设施**（批六 ② 候选 2 · 判据 d）—— 注入一条"会话被打断"通知，用来验探测闸门的收敛。
///
/// ## 为什么需要它
///
/// 判据 d 要验的是"探测被打断时**收敛到兜底格式 + 不写缓存**"。但真正的
/// `videoDeviceInUseByAnotherClient`（raw 3）需要**另一个客户端抢设备** —— 那正是已经删掉的
/// 设备级预热干的事；前台主摄常开时系统不会自发产生 raw 3 → **不可自然触发**
/// （2026-09-22 凌晨 Mac 实测确认：前台触发不了）。
///
/// ## 做法：自造通知（**不碰真实设备**）
///
/// 只走我方回调（置闩 + 打日志），**不改变任何真实会话/设备状态** → 零黑屏风险、可控复现。
///
/// 🔴 **`object:` 必须传与订阅时同一个 `session` 实例** —— 观察者订阅时写的是 `object: session`，
/// 传 nil 或别的对象**收不到**（这是注入失败最常见的原因，写死在这条）。
///
/// ## 开关（启动参数 / UserDefaults 的 arguments 域，优先级最高）
///
/// ```
/// -lumen.debug.probeInterruptRaw 3      // 注入的 raw：
///                                       //   3 = 被另一个客户端占用（**非良性 → 应收手**）
///                                       //   1 = 后台不可用（**良性 → 应不收手**）
///                                       // 不传 = 完全不注入（默认）
/// -lumen.debug.probeInterruptAt 1       // 在第 1 次 applyFormat 之后注入（默认 1）
/// -lumen.debug.probeInterruptAsync YES  // 从后台线程延迟 50ms 注入（模拟真实通知的异线程到达）
/// ```
///
/// ## ⚠️ 这是**验收设施**，不是产品功能
///
/// 有效逻辑整体在 `#if DEBUG` 内，且**一次性**（`injected`，避免连环注入把探测反复打断）。
/// **验收通过后请连同控制器里那 1 行调用一起删除**（收尾清单已列）。
///
/// ⚠️ 结构上有意写成「**一个类型 + 一个成员 + `#if` 在函数体内**」：
/// `check_swift` 的"顶层类型重名 / 同类型成员重复"是**文本级**检查，若写成 `#if … enum … #else … enum … #endif`
/// 会被算成重复声明（本文件第一版就是这么被拦下的）。同理 Release 分支用 `_ =` 吃掉参数，
/// 不另开一个同名函数。
enum DebugProbeInterrupt {

    /// 一次性闩（Release 下不参与逻辑，但保留**单一声明**，理由见类型头注释）
    private static var injected = false

    /// 在第 `attempt` 次 `applyFormat` **之后**调用 —— 命中配置点就注入一条"被打断"通知。
    ///
    /// - Parameter attempt: 本次探测里已经跑完的 `applyFormat` 次数（从 1 开始）
    /// - Parameter session: **必须与观察者订阅时的 object 同一个实例**（见类型头 🔴）
    static func maybeInject(afterAttempt attempt: Int, session: AVCaptureSession) {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard !injected, defaults.object(forKey: "lumen.debug.probeInterruptRaw") != nil else { return }
        let raw = defaults.integer(forKey: "lumen.debug.probeInterruptRaw")
        let at = defaults.object(forKey: "lumen.debug.probeInterruptAt") != nil
            ? defaults.integer(forKey: "lumen.debug.probeInterruptAt")
            : 1
        guard attempt >= at else { return }
        injected = true

        let isAsync = defaults.bool(forKey: "lumen.debug.probeInterruptAsync")
        DebugLog.shared.warn(
            "session",
            "【debug】注入打断通知：raw \(raw)（第 \(attempt) 次候选后"
                + (isAsync ? " · 后台线程延迟 50ms" : " · 同步") + "）"
        )
        let post = {
            NotificationCenter.default.post(
                name: AVCaptureSession.wasInterruptedNotification,
                object: session,                                   // 🔴 必须与订阅的 object 一致
                userInfo: [AVCaptureSessionInterruptionReasonKey: raw]
            )
        }
        if isAsync {
            // 模拟真实通知：系统是在**别的线程**上把打断抛过来的（这条用来验"闩不排队也可见"）
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + .milliseconds(50), execute: post)
        } else {
            post()
        }
        #else
        // Release：空实现。保留同签名 → 控制器调用点能保持一行（否则那里也要包 #if DEBUG，收尾删两处）
        _ = attempt
        _ = session
        #endif
    }
}
