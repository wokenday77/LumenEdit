import SwiftUI

/// 根路由。
///
/// P1a 只有相机页，所以这里看起来"没什么东西"——但它是后面阶段的落点：
/// P3 加相册页、P4 加修图页时，只改这个文件即可，`LumenEditApp` 不用动。
struct AppRouter: View {

    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        CameraView()
            .sheet(isPresented: $env.showSettings) {
                SettingsSheet()
                    .environmentObject(env)
            }
    }
}

// MARK: - 设置页

/// 设置页。P1a 阶段的定位是"排障工具 + 权限总览"，
/// 而不是功能设置——功能设置（默认格式、分辨率、保存位置）留到 P2。
struct SettingsSheet: View {

    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var permissionText: String = "读取中…"
    @State private var logPreview: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("调试") {
                    Toggle("显示调试浮层", isOn: $env.showDebugHUD)
                    Text("真机侧载运行时没有 Xcode 控制台，浮层会实时显示设备、格式、帧率、曝光和最近的错误。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("权限") {
                    Text(permissionText)
                        .font(.footnote.monospaced())
                    Button("重新读取权限状态") {
                        Task {
                            await env.refreshPermissions()
                            permissionText = env.permissionSummary()
                        }
                    }
                    Button("打开系统设置") {
                        env.permissions.openSystemSettings()
                    }
                }

                Section("日志") {
                    Text("日志同时写入 OSLog 和 App 沙盒文件，侧载运行时可用系统分享导出。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ShareLink(item: env.logFileURL) {
                        Label("导出日志文件", systemImage: "square.and.arrow.up")
                    }
                    Button("刷新预览") {
                        reloadLogPreview()
                    }
                    if !logPreview.isEmpty {
                        ScrollView {
                            Text(logPreview)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: Self.appVersion)
                    LabeledContent("阶段", value: "P1a · 照片采集闭环")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                permissionText = env.permissionSummary()
                reloadLogPreview()
            }
        }
    }

    private func reloadLogPreview() {
        logPreview = DebugLog.shared.exportText(maxLines: 60)
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
