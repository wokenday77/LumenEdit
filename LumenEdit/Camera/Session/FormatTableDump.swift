import AVFoundation
import Foundation

// ⚠️ **临时诊断文件**（批六 ② P-b 取证用 · 2026-09-21 夜 · Mac 加）—— **取到数据即删**。
//
// 目的：把三颗物理镜头的 `device.formats` **全表**原样打进日志，供 WB 回算
//      「Live 命中档在元数据排序里排第几」，并观察"单次 applyFormat 代价 vs 格式描述子"的关系
//      （现场读数：超广角 ≈1ms/次，Back/Tele ≈0.3s/次，差 ~300 倍）。
//
// 口径说明：
// - `identity` 与 `CaptureSessionController.formatIdentity` **同式复写**（那边是 private；
//   改可见性 = 动批六代码，这里刻意只读不改）。
// - 「真跑得到的 Live 位值」只标**预热真跑命中的那一档**（拿缓存里的 identity 比对）——
//   逐档真跑要 40+ 次 applyFormat/颗（≈30~60s 一直占着 constituent 设备），
//   那正是当前要排查的冲突源，故不在此处做；WB 若需要逐档 Live 位值另开一次专用采集。
enum FormatTableDump {

    private static let doneKey = "lumen.diag.formatTableDumped"

    /// 每进程只打一次（挂在 `startInternal` 上，冷启动会走两次 —— 这里自己收口）。
    static func logOnce(cachedHits: [String: String]) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        UserDefaults.standard.set(true, forKey: doneKey)

        let hitIdentities = Set(cachedHits.values)

        // 与预热同源：FocalCatalog 的焦段 → 物理镜头，按 uniqueID 去重
        var seen = Set<String>()
        var devices: [AVCaptureDevice] = []
        for preset in FocalCatalog.all {
            guard let device = CaptureCapabilities.physicalDevice(for: preset),
                  !seen.contains(device.uniqueID) else { continue }
            seen.insert(device.uniqueID)
            devices.append(device)
        }

        for device in devices {
            DebugLog.shared.info(
                "diag",
                "── device.formats 全表：\(device.localizedName) · \(device.formats.count) 个 "
                    + "· activeFormat 已在用 ──"
            )
            for (index, format) in device.formats.enumerated() {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let subType = format.formatDescription.mediaSubType.rawValue
                let ranges = format.videoSupportedFrameRateRanges
                let minFPS = ranges.map(\.minFrameRate).min() ?? 0
                let maxFPS = ranges.map(\.maxFrameRate).max() ?? 0
                // ⚠️ 与 `formatIdentity` 同式（见文件头：刻意复写，不改那边可见性）
                let identity = "\(dimensions.width)x\(dimensions.height)|\(subType)"
                    + "|\(String(format: "%.0f", minFPS))-\(String(format: "%.0f", maxFPS))"
                let maxPhoto = format.supportedMaxPhotoDimensions
                    .map { "\($0.width)x\($0.height)" }
                    .joined(separator: "/")
                let binned = format.isVideoBinned ? "binned=Y" : "binned=N"
                let hit = hitIdentities.contains(identity) ? "   ← 预热真跑命中（Live=true）" : ""
                DebugLog.shared.info(
                    "diag",
                    "#\(String(format: "%02d", index)) \(identity)"
                        + " photoMax=\(maxPhoto.isEmpty ? "—" : maxPhoto) \(binned)\(hit)"
                )
            }
        }
        DebugLog.shared.info("diag", "── device.formats 全表打印结束（三颗）──")
    }
}
