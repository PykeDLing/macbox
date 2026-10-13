import AppKit
import SwiftUI

/// 主窗口里的「设置」页
struct SettingsPage: View {
    @Environment(BoxStore.self) private var store
    @AppStorage(CompatibilityPolicy.key) private var policy = CompatibilityPolicy.ask.rawValue
    @AppStorage("defaultShowInLaunchpad") private var showInLaunchpad = true

    var body: some View {
        Form {
            Section {
                Picker("出现兼容性问题时", selection: $policy) {
                    ForEach(CompatibilityPolicy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("应用需要安装系统组件（驱动、系统服务、系统扩展等）时，本机隔离会挡住这些操作，软件功能可能不完整。开机自启动被挡住不影响使用，不会提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("兼容性")
            }

            Section("新添加的应用") {
                Toggle("在启动台和聚焦中显示", isOn: $showInLaunchpad)
                Text("启动器放在 ~/Applications/MacBox，打开时由 MacBox 在隔离中启动真正的应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("本机隔离会做什么") {
                IsolationFact(icon: "folder.badge.person.crop", text: "应用看到的是盒子里的主目录：设置、缓存、登录状态都存在 MacBox 里")
                IsolationFact(icon: "key", text: "每个应用一个独立钥匙串，不会写进你的「登录」钥匙串")
                IsolationFact(icon: "hand.raised", text: "阻止写入系统目录、注册开机自启动和后台服务、发送通知、遥控其他 App")
                IsolationFact(icon: "eye.slash", text: "阻止读取邮件、信息、Safari、其他应用的数据和 SSH 密钥")
                IsolationFact(icon: "shield.lefthalf.filled", text: "运行时守卫：盒子里的程序一旦在沙盒外被启动，立即结束")
            }

            Section("存储") {
                LabeledContent("应用数据位置") {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.boxes]) }
                }
                LabeledContent("虚拟 Mac") {
                    Button("前往「虚拟 Mac」页") { store.destination = .virtualMac }
                }
            }

            Section {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .pageWidth()
        .navigationTitle("设置")
        .navigationSubtitle("")
    }
}

private struct IsolationFact: View {
    let icon: String
    let text: String
    var body: some View {
        Label { Text(text).font(.callout) } icon: { Image(systemName: icon).foregroundStyle(.tint) }
    }
}
