import SwiftUI
import UIKit

struct ContentView: View {
    private static let statusRefreshQueue = DispatchQueue(label: "com.kianuni.lokey.audit.statusRefresh", qos: .utility)

    @Environment(\.scenePhase) private var scenePhase
    @State private var sandboxText: String = ""
    @State private var isKeyboardEnabled: Bool = false
    @State private var bridgeStatus: LokeyAppGroupBridgeStatus = .init(
        hostGroups: [],
        extensionGroups: [],
        resolvedGroupID: nil,
        hasEntitlementMismatch: false,
        extensionHeartbeat: nil
    )
    @State private var hasLoadedStatus: Bool = false
    @FocusState private var isSandboxFocused: Bool

    private let appVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.5"
    private let buildVersion: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "88"

    var body: some View {
        NavigationStack {
            List {
                // Status Hero
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 52, height: 52)
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Lokey Audit")
                                    .font(.headline)
                                Text("v\(appVersion) (\(buildVersion))")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                            Text(isKeyboardEnabled ? "已在系统键盘列表中启用" : "若已添加键盘，请在下方试打框按 🌐 切至 Lokey")
                                .font(.subheadline)
                                .foregroundStyle(isKeyboardEnabled ? .green : .orange)
                            if hasLoadedStatus {
                                if let gid = bridgeStatus.resolvedGroupID {
                                    if bridgeStatus.extensionHeartbeat?.hasFullAccess == true {
                                        Text("App Group 容器已连通 (\(gid)) · 完全访问已开启")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("App Group 容器已就绪 (\(gid)) · 未开启完全访问仍可 100% 离线打字")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("标准独立沙盒模式运行中（100% 离线可用）")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Live Typing Sandbox
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("点此唤起键盘试打（按 🌐 切换至 Lokey）…", text: $sandboxText, axis: .vertical)
                            .lineLimit(3...6)
                            .focused($isSandboxFocused)
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        HStack {
                            Text("试打用例：nihao / zhongguo / beijing / wojintianxiawuyoukong / iphone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !sandboxText.isEmpty {
                                Button("清空") {
                                    sandboxText = ""
                                }
                                .font(.caption.weight(.medium))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("实时输入体验沙盒")
                }

                // Setup Instructions
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("1. 启用 Lokey 键盘（可选「允许完全访问」）")
                                .font(.subheadline.weight(.medium))
                            Text("前往「设置 -> 通用 -> 键盘 -> 键盘 -> 添加新键盘」选择 Lokey。关闭「允许完全访问」（hasFullAccess == false）即可使用内置示范词库 100% 离线全拼打字；开启完全访问仅用于本机 App Group 状态同步与按键震动/音效反馈。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.indigo)
                    }

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Text("打开系统设置")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                } header: {
                    Text("启用说明")
                }

                // Zero-Network Physical Isolation & Source-Available Audit Notice
                Section {
                    LabeledContent("输入法内核引擎", value: LokeySessionController.engineDisplayName)
                    LabeledContent("联网框架与 Socket 符号", value: "0（物理级纯离线）")
                    LabeledContent("内置敏感词审查表", value: "0（无过滤表）")

                    VStack(alignment: .leading, spacing: 6) {
                        Label("100% 物理零联网承诺", systemImage: "lock.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("Lokey-Audit 包含与商业版完全一致、未经删改的 Shared/Engine 与 KeyboardExtension 全套 Swift 源码，搭配最小化开放许可示范词库（demo_lexicon.bin）。全工程不含任何网络框架、Socket 系统调用或远端遥测代码。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地 Mach-O 与源码审计命令")
                            .font(.subheadline.weight(.semibold))
                        Text("• ./scripts/audit_zero_network.sh --source-only\n• ./scripts/audit_zero_network.sh <DerivedData_or_.app>\n• otool -L <Binary> && nm -u <Binary>")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("第三方开源许可声明")
                            .font(.subheadline.weight(.semibold))
                        Text("示范词库、简繁转换与字符映射资源的第三方开源许可证文本详见仓库 LICENSES/ 目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source-Available Security Audit Notice")
                            .font(.subheadline.weight(.semibold))
                        Text("本仓库仅授权用于安全审计、离线编译与本地测试验证；禁止未授权分发 .ipa 二进制安装包或用于商业/App Store 重新上架（详见仓库根目录 LICENSE）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("隐私承诺（100% 物理零联网）与许可声明")
                }
            }
            .navigationTitle("Lokey Audit")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") {
                        isSandboxFocused = false
                    }
                }
            }
            .onAppear {
                refreshStatus()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    refreshStatus()
                }
            }
        }
    }

    private func refreshStatus() {
        Self.statusRefreshQueue.async {
            let status = LokeyAppGroup.inspectBridgeStatus()
            let marker = LokeyAppGroup.hasExtensionActivationMarker()
            DispatchQueue.main.async {
                let hasActiveChineseInputMode = UITextInputMode.activeInputModes.contains { mode in
                    guard let lang = mode.primaryLanguage?.lowercased() else { return false }
                    return lang.hasPrefix("zh")
                }
                let hasActivationMarker = marker || status.extensionHeartbeat != nil
                bridgeStatus = status
                isKeyboardEnabled = hasActiveChineseInputMode && hasActivationMarker
                hasLoadedStatus = true
            }
        }
    }
}
