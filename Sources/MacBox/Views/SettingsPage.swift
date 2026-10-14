import AppKit
import SwiftUI

/// 主窗口里的「设置」页
struct SettingsPage: View {
    @Environment(BoxStore.self) private var store
    @AppStorage(CompatibilityPolicy.key) private var policy = CompatibilityPolicy.ask.rawValue
    @AppStorage("defaultShowInLaunchpad") private var showInLaunchpad = true
    private let localization = Localization.shared

    var body: some View {
        Form {
            Section {
                Picker(L("界面语言", "Display Language"), selection: Binding(get: { localization.language },
                                                                set: { localization.language = $0 })) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                Text(L("系统提供的文字（如菜单栏里的“退出”“编辑”、选择文件的窗口）在退出并重新打开 MacBox 后切换。",
                       "System-provided text (such as the Quit and Edit menu items and file dialogs) switches after you quit and reopen MacBox."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("语言", "Language"))
            }

            Section {
                Picker(L("出现兼容性问题时", "When an App Has Compatibility Issues"), selection: $policy) {
                    ForEach(CompatibilityPolicy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text(L("应用需要安装系统组件（驱动、系统服务、系统扩展等）时，本机隔离会挡住这些操作，软件功能可能不完整。开机自启动被挡住不影响使用，不会提示。",
                       "When an app needs to install system components (drivers, system services, system extensions and so on), Native Isolation blocks them and some features may not work. Blocked launch-at-login items don't affect use and aren't reported."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("兼容性", "Compatibility"))
            }

            Section(L("新添加的应用", "New Apps")) {
                Toggle(L("在聚焦中显示", "Show in Spotlight"), isOn: $showInLaunchpad)
                Text(L("启动器放在 ~/Applications/MacBox，打开时由 MacBox 在隔离中启动真正的应用。",
                       "Launchers go in ~/Applications/MacBox. Opening one has MacBox start the real app in isolation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("本机隔离会做什么", "What Native Isolation Does")) {
                IsolationFact(icon: "folder.badge.person.crop", text: L("应用看到的是盒子里的主目录：设置、缓存、登录状态都存在 MacBox 里",
                                                                        "The app sees the box as its home folder: settings, caches and sign-ins are stored in MacBox"))
                IsolationFact(icon: "key", text: L("每个应用一个独立钥匙串，不会写进你的「登录」钥匙串",
                                                   "Each app gets its own keychain and never writes to your “login” keychain"))
                IsolationFact(icon: "hand.raised", text: L("阻止写入系统目录、注册开机自启动和后台服务、发送通知、遥控其他 App",
                                                           "Blocks writing to system folders, registering login items and background services, sending notifications and controlling other apps"))
                IsolationFact(icon: "eye.slash", text: L("阻止读取邮件、信息、Safari、其他应用的数据和 SSH 密钥",
                                                         "Blocks reading Mail, Messages, Safari, other apps’ data and SSH keys"))
                // 守卫随 MacBox 进程存在：MacBox 没开时绕过它直接打开盒子里的 App 拦不住，不能写成无条件的
                IsolationFact(icon: "shield.lefthalf.filled", text: L("运行时守卫：MacBox 打开期间，盒子里的程序一旦在沙盒外被启动，立即结束",
                                                                      "Runtime guard: while MacBox is open, any program from a box launched outside the sandbox is ended immediately"))
            }

            Section(L("存储", "Storage")) {
                LabeledContent(L("应用数据位置", "App Data Location")) {
                    Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.boxes]) }
                }
                LabeledContent(L("虚拟 Mac", "Virtual Mac")) {
                    Button(L("前往「虚拟 Mac」页", "Go to Virtual Mac")) { store.destination = .virtualMac }
                }
            }

            Section {
                LabeledContent(L("版本", "Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .pageWidth()
        .navigationTitle(L("设置", "Settings"))
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
