import AVFoundation
import Foundation

/// 音频会话管理。
///
/// 相机 App 里音频会话只有两种状态：**需要录音时激活，其余时间必须释放**。
///
/// 为什么必须释放（这条最容易漏）：
/// - 占着不放会一直持有音频硬件，别的 App（音乐、播客）没法正常播放，而且持续耗电；
/// - 释放时一定要带 `.notifyOthersOnDeactivation`，否则系统不会通知其它 App 恢复播放，
///   用户会觉得"用了你这个相机，网易云就不出声了"。
///
/// 本类在 P1a 阶段不会被真正激活（照片模式不需要麦克风），
/// 但代码是完整的——P1b 打开视频与 Live Photo 后，`CaptureSessionController`
/// 会自动在切到那些模式时激活、切走时释放，不需要再改这里。
final class AudioSessionManager {

    // MARK: - 错误

    enum AudioSessionError: LocalizedError {
        case categoryConfigurationFailed(String)
        case activationFailed(String)

        var errorDescription: String? {
            switch self {
            case .categoryConfigurationFailed(let message):
                return "音频会话类别配置失败：\(message)"
            case .activationFailed(let message):
                return "音频会话激活失败（可能被其它 App 占用）：\(message)"
            }
        }
    }

    // MARK: - 状态

    private let session = AVAudioSession.sharedInstance()
    private let stateLock = NSLock()
    private var _isActive = false
    private var interruptionObserver: NSObjectProtocol?

    /// 当前是否已激活。注意系统可能在来电等场景下强制取消激活，
    /// 这个值会通过中断通知同步更新。
    var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isActive
    }

    init() {
        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - 激活 / 释放

    /// 进入「录制视频」场景：Live Photo 与视频录制都需要音轨。
    ///
    /// 类别选 `.playAndRecord` + 模式 `.videoRecording`，与系统相机一致；
    /// 选项 `.defaultToSpeaker` 保证回放走扬声器而不是听筒。
    func activateForRecording() throws {
        if isActive { return }

        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
        } catch {
            throw AudioSessionError.categoryConfigurationFailed(error.localizedDescription)
        }

        // 这两个是"偏好值"，硬件不支持时会被系统忽略，所以失败只记录不抛错
        do {
            try session.setPreferredSampleRate(48_000)
        } catch {
            DebugLog.shared.warn("audio", "设置偏好采样率失败（忽略）：\(error.localizedDescription)")
        }
        do {
            try session.setPreferredIOBufferDuration(0.005)
        } catch {
            DebugLog.shared.warn("audio", "设置偏好 IO 缓冲失败（忽略）：\(error.localizedDescription)")
        }

        do {
            try session.setActive(true, options: [])
        } catch {
            throw AudioSessionError.activationFailed(error.localizedDescription)
        }

        setActiveFlag(true)
        DebugLog.shared.info("audio", "音频会话已激活（\(debugDescription())）")
    }

    /// 释放音频会话。**离开相机页或切回照片模式时必须调用。**
    func deactivate() {
        guard isActive else { return }
        do {
            // notifyOthersOnDeactivation：让被我们打断的音乐等 App 自动恢复
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            setActiveFlag(false)
            DebugLog.shared.info("audio", "音频会话已释放")
        } catch {
            DebugLog.shared.warn("audio", "释放音频会话失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 诊断

    func debugDescription() -> String {
        let category = session.category.rawValue
        let mode = session.mode.rawValue
        let sampleRate = session.sampleRate
        let channels = session.inputNumberOfChannels
        return String(
            format: "active=%@ category=%@ mode=%@ %.0fHz ch=%d",
            isActive ? "true" : "false",
            category,
            mode,
            sampleRate,
            channels
        )
    }

    // MARK: - 私有

    private func setActiveFlag(_ value: Bool) {
        stateLock.lock()
        _isActive = value
        stateLock.unlock()
    }

    /// 来电、闹钟等会打断音频会话，系统会强制取消激活。
    /// 这里只做状态同步与记录——"要不要恢复录音"属于业务决策，交给上层（P1b）。
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else {
                return
            }

            switch type {
            case .began:
                self.setActiveFlag(false)
                DebugLog.shared.warn("audio", "音频会话被系统中断（来电/闹钟等）")

            case .ended:
                let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                let shouldResume = options.contains(.shouldResume)
                DebugLog.shared.info("audio", "音频中断结束，系统建议恢复=\(shouldResume)")

            @unknown default:
                break
            }
        }
    }
}
