import SwiftUI
import UniformTypeIdentifiers

/// 弹出「添加应用」的文件选择框，用法同 SwiftUI 的 OpenWindowAction：`importApps()`
struct ImportAppsAction: Equatable {
    let isPresented: Binding<Bool>
    func callAsFunction() { isPresented.wrappedValue = true }
    /// 始终指向主窗口的同一个状态，比较时视为相等，环境变化不会让读取它的视图重绘
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// 由主窗口提供，侧边栏、卡片、欢迎页共用
    @Entry var importApps = ImportAppsAction(isPresented: .constant(false))
}

extension FocusedValues {
    /// 菜单「文件 › 添加应用…」(⌘O)；主窗口不在前台时为 nil，菜单项自动变灰
    @Entry var importApps: ImportAppsAction?
}

extension UTType {
    /// 可以放进 MacBox 的安装包
    static let installers: [UTType] = ["dmg", "app", "pkg", "mpkg", "zip"].compactMap { UTType(filenameExtension: $0) }
}

extension View {
    /// 设置类页面在宽窗口里不要拉得太宽
    func pageWidth() -> some View {
        frame(maxWidth: 720).frame(maxWidth: .infinity)
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("关闭", "Close"))
        }
        .font(.callout)
    }
}

struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(color).font(.system(size: 7))
            configuration.title
        }
    }
}
