import Foundation
import os

// MARK: - 日志级别

enum LogLevel: String {
    case debug = "DBG"
    case info = "INF"
    case warn = "WRN"
    case error = "ERR"

    var isNotable: Bool { self != .debug }
}

// MARK: - 日志条目

struct LogEntry: Identifiable, Equatable {
    let id: UInt64
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String

    var timeText: String {
        LogEntry.timeFormatter.string(from: timestamp)
    }

    var line: String {
        "[\(timeText)] \(level.rawValue) [\(category)] \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - 日志中枢

/// 日志中枢：同时写 OSLog 和 App 沙盒文件。
///
/// **为什么必须写文件**：我们的运行方式是「云端 Mac 编译 + 侧载到 iPhone」，
/// 这条链路上没有 Xcode 控制台。相机模块的问题（权限时序、格式不支持、参数越界）
/// 只靠肉眼看现象几乎排不出来，所以必须把日志落到沙盒里，用户可在设置页分享出来。
///
/// 线程安全：`log` 可从任意线程调用（AVFoundation 回调都在私有队列上）。
/// 内存环形缓冲用锁保护，@Published 的更新统一回主线程。
final class DebugLog: ObservableObject {

    static let shared = DebugLog()

    /// 最近若干条日志，供调试浮层展示
    @Published private(set) var recent: [LogEntry] = []

    /// 沙盒内日志文件位置
    let fileURL: URL

    private let maxRecentEntries = 200
    private static let maxFileBytes = 512 * 1024
    private static let keptLinesAfterRotation = 800
    private let fileQueue = DispatchQueue(label: "com.lumenedit.log.file", qos: .utility)
    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.lumenedit.app", category: "LumenEdit")

    private var buffer: [LogEntry] = []
    private var counter: UInt64 = 0

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("lumen-debug.log")
    }

    // MARK: - 生命周期

    /// 在 App 启动最早期调用一次
    func bootstrap() {
        let header = """

        ============================================================
        LumenEdit 日志启动 \(Self.timestampText())
        device=\(Self.deviceModelIdentifier())  system=\(Self.systemVersion())
        ============================================================

        """
        fileQueue.async { [fileURL] in
            let manager = FileManager.default
            if !manager.fileExists(atPath: fileURL.path) {
                try? header.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            } else {
                Self.append(Data(header.utf8), to: fileURL)
            }
        }
    }

    // MARK: - 写入

    func log(_ level: LogLevel, _ category: String, _ message: String) {
        lock.lock()
        counter &+= 1
        let entry = LogEntry(id: counter, timestamp: Date(), level: level, category: category, message: message)
        buffer.append(entry)
        if buffer.count > maxRecentEntries {
            buffer.removeFirst(buffer.count - maxRecentEntries)
        }
        let snapshot = buffer
        lock.unlock()

        switch level {
        case .debug: osLogger.debug("\(entry.line, privacy: .public)")
        case .info: osLogger.info("\(entry.line, privacy: .public)")
        case .warn: osLogger.warning("\(entry.line, privacy: .public)")
        case .error: osLogger.error("\(entry.line, privacy: .public)")
        }

        fileQueue.async { [fileURL] in
            Self.append(Data((entry.line + "\n").utf8), to: fileURL)
            Self.rotateIfNeeded(fileURL: fileURL)
        }

        // debug 级别的日志不推给 UI，避免频繁刷新列表
        if level.isNotable {
            DispatchQueue.main.async { [weak self] in
                self?.recent = snapshot
            }
        }
    }

    func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    func info(_ category: String, _ message: String) { log(.info, category, message) }
    func warn(_ category: String, _ message: String) { log(.warn, category, message) }
    func error(_ category: String, _ message: String) { log(.error, category, message) }

    // MARK: - 导出与清理

    /// 取日志尾部文本，用于设置页预览
    func exportText(maxLines: Int = 200) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return "(日志文件尚未生成)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines {
            return text
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        counter = 0
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.recent = []
        }

        fileQueue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    // MARK: - 私有实现

    private static func append(_ data: Data, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 日志写失败不能再抛，否则会掩盖真正的业务错误
        }
    }

    /// 文件超过上限就裁掉前半部分，保留最近的记录，防止沙盒无限增长
    private static func rotateIfNeeded(fileURL: URL) {
        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int,
              size > maxFileBytes else { return }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(keptLinesAfterRotation)
        let trimmed = "[日志已截断，仅保留最近 \(keptLinesAfterRotation) 行]\n" + kept.joined(separator: "\n")
        if let data = trimmed.data(using: .utf8) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func timestampText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
