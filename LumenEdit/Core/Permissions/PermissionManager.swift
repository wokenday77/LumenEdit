import AVFoundation
import Foundation
import Photos
import UIKit

/// 权限状态机：相机 / 麦克风 / 相册（写入）/ 相册（读取）。
///
/// 设计要点：
/// 1. 用显式 continuation 包系统回调，而不是依赖 ObjC 自动生成的 async 版本，
///    这样在不同 Xcode 版本上行为一致，不会因为导入方式的差异编译失败。
/// 2. `refreshAll()` 在每次回到前台时调用，覆盖"用户去系统设置里改完权限再回来"的场景。
/// 3. 相册写入用 `.addOnly`，只申请"添加"权限——避免一上来就要完整相册访问权，
///    拒绝率低得多，体验也更好。
@MainActor
final class PermissionManager: ObservableObject {

    enum Status: Equatable {
        case notDetermined
        case authorized
        case limited
        case denied
        case restricted

        var displayName: String {
            switch self {
            case .notDetermined: return "未决定"
            case .authorized: return "已授权"
            case .limited: return "部分授权"
            case .denied: return "已拒绝"
            case .restricted: return "受系统限制"
            }
        }

        var isUsable: Bool {
            self == .authorized || self == .limited
        }

        /// 能否再次弹系统授权框（只有"未决定"可以）
        var canPrompt: Bool { self == .notDetermined }
    }

    @Published private(set) var camera: Status = .notDetermined
    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var photoLibraryAdd: Status = .notDetermined
    @Published private(set) var photoLibraryRead: Status = .notDetermined

    // MARK: - 刷新

    func refreshAll() async {
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        photoLibraryAdd = Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        photoLibraryRead = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        DebugLog.shared.debug(
            "perm",
            "刷新权限 camera=\(camera.displayName) mic=\(microphone.displayName) "
            + "albumAdd=\(photoLibraryAdd.displayName) albumRead=\(photoLibraryRead.displayName)"
        )
    }

    // MARK: - 申请

    @discardableResult
    func requestCamera() async -> Bool {
        if camera.canPrompt {
            let granted = await Self.requestCaptureAccess(for: .video)
            DebugLog.shared.info("perm", "申请相机权限结果：\(granted)")
        }
        await refreshAll()
        return camera.isUsable
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        if microphone.canPrompt {
            let granted = await Self.requestCaptureAccess(for: .audio)
            DebugLog.shared.info("perm", "申请麦克风权限结果：\(granted)")
        }
        await refreshAll()
        return microphone.isUsable
    }

    @discardableResult
    func requestPhotoLibraryAdd() async -> Bool {
        if photoLibraryAdd.canPrompt {
            let status = await Self.requestPhotoAuthorization(for: .addOnly)
            DebugLog.shared.info("perm", "申请相册写入权限结果：\(status.rawValue)")
        }
        await refreshAll()
        return photoLibraryAdd.isUsable
    }

    @discardableResult
    func requestPhotoLibraryRead() async -> Bool {
        if photoLibraryRead.canPrompt {
            let status = await Self.requestPhotoAuthorization(for: .readWrite)
            DebugLog.shared.info("perm", "申请相册读取权限结果：\(status.rawValue)")
        }
        await refreshAll()
        return photoLibraryRead.isUsable
    }

    // MARK: - 系统设置

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DebugLog.shared.info("perm", "跳转系统设置")
        UIApplication.shared.open(url)
    }

    // MARK: - 私有：状态映射

    private static func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> Status {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    // MARK: - 私有：异步包装

    private static func requestCaptureAccess(for mediaType: AVMediaType) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func requestPhotoAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
