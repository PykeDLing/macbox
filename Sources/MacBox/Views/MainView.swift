import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：左侧导航（应用 / 虚拟 Mac / 设置），右侧是对应页面
struct MainView: View {
    @Environment(BoxStore.self) private var store
    @State private var dropTargeted = false
    @State private var importing = false
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            switch store.destination {
            // 两个应用页共用同一个视图，切换时详情栏等状态不会重置
            case .allApps, .running: LibraryView(runningOnly: store.destination == .running, query: query)
            case .virtualMac: VirtualMacPage()
            case .settings: SettingsPage()
            }
        }
        // 搜索框放在侧边栏顶部，不和右侧详情栏挤在一起；在其他页面输入时跳回应用页
        .searchable(text: $query, placement: .sidebar, prompt: String(localized: "搜索应用"))
        .onChange(of: query) {
            if !query.isEmpty && store.destination != .allApps && store.destination != .running {
                store.destination = .allApps
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .environment(\.importApps, ImportAppsAction(isPresented: $importing))
        // 正在退出 MacBox 时不再添加：菜单「添加应用…」变灰
        .focusedSceneValue(\.importApps, store.isTerminating ? nil : ImportAppsAction(isPresented: $importing))
        .fileImporter(isPresented: $importing, allowedContentTypes: UTType.installers, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            store.destination = .allApps
            Task { await store.importItems(urls) }
        }
        .fileDialogDefaultDirectory(.downloadsDirectory)
        .fileDialogMessage(String(localized: "选择要放进 MacBox 的应用"))
        // 任何页面都可以把安装包拖进来
        .overlay { if dropTargeted { DropHighlight() } }
        .dropDestination(for: URL.self) { urls, _ in
            store.destination = .allApps
            Task { await store.importItems(urls) }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        // 退出 MacBox 要等应用退出、收尾做完，可能要一会儿：说明在做什么，期间打开、添加都不会生效
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isTerminating { QuittingBanner() }
        }
        // 下面几种提示都排队，一次显示一条。按钮只做选择对应的事，移出队列统一在关闭时做（isPresented 被置为 false）：
        // 按钮里就移出的话，关闭时 SwiftUI 再置一次 false，会把排在后面的那条也当成已关闭
        .alert(store.prompt?.title ?? "",
               isPresented: Binding(get: { store.prompt != nil }, set: { [id = store.prompt?.id] in
                   // 按显示着的那条的 id 移出：同一次关闭里再置一次 false、或者绑定已经换成下一条时，都不会误关下一条
                   if !$0, let id { store.dismissPrompt(id: id) }
               }),
               presenting: store.prompt) { prompt in
            Button("改用虚拟 Mac") { store.box(id: prompt.boxID)?.config.runtime = .virtualMac }
            // 记下这次的拦截：同样的拦截以后不再问，每次退出都弹一次没有意义
            Button("继续使用本机隔离", role: .cancel) { store.keepNativeIsolation(prompt) }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert(String(localized: "「\(store.virtualMacOffers.first?.file.lastPathComponent ?? "")」需要在虚拟 Mac 里安装"),
               isPresented: Binding(get: { !store.virtualMacOffers.isEmpty }, set: { if !$0 { store.dismissVirtualMacOffer() } }),
               presenting: store.virtualMacOffers.first) { offer in
            Button("放进虚拟 Mac") { Task { await store.sendToVirtualMac(offer) } }
            Button("取消", role: .cancel) {}
        } message: { offer in
            Text(offer.message + "\n\n" + String(localized: "可以把它放进虚拟 Mac 的「传入」文件夹，在虚拟 Mac 里安装。"))
        }
        .alert(store.alerts.first?.title ?? "",
               isPresented: Binding(get: { !store.alerts.isEmpty }, set: { if !$0 { store.dismissAlert() } }),
               presenting: store.alerts.first) { _ in
            Button("好") {}
        } message: { alert in
            Text(alert.message)
        }
        .alert("无法添加",
               isPresented: Binding(get: { store.importError != nil }, set: { if !$0 { store.importError = nil } }),
               presenting: store.importError) { _ in
            Button("好") {}
        } message: { message in
            Text(message)
        }
    }

}

/// 正在退出 MacBox：等应用退出、收尾、维护和添加做完
private struct QuittingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在退出 MacBox…等应用退出、做完收尾后就会退出。")
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 侧边栏

private struct Sidebar: View {
    @Environment(BoxStore.self) private var store
    @Environment(VirtualMac.self) private var virtualMac
    @Environment(\.importApps) private var importApps

    var body: some View {
        List(selection: Binding(get: { store.destination }, set: { if let value = $0 { store.destination = value } })) {
            Section("应用") {
                Label("全部应用", systemImage: "square.grid.2x2")
                    .badge(store.boxes.count)
                    .tag(Destination.allApps)
                Label("运行中", systemImage: "play.circle")
                    .badge(store.runningBoxes.count)
                    .tag(Destination.running)
            }
            Section("运行环境") {
                Label("虚拟 Mac", systemImage: "desktopcomputer")
                    .badge(virtualMacBadge)
                    .tag(Destination.virtualMac)
            }
            Section("MacBox") {
                Label("设置", systemImage: "gearshape")
                    .tag(Destination.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Button { importApps() } label: {
                    Label("添加应用", systemImage: "plus")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isTerminating)
                .help("选择 .dmg、.app、.pkg 或 .zip（⌘O）")
                Text("也可以把安装包拖进窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var virtualMacBadge: Text? {
        switch virtualMac.status {
        case .notSetUp: Text("未设置")
        case .unreadable: Text("无法读取")
        // 和「虚拟 Mac」页、窗口标题用同一套说法（关机但留有睡眠状态时是「睡眠中」）
        case .stopped: virtualMac.isAsleep ? Text(virtualMac.displayStatus) : nil
        default: Text(virtualMac.displayStatus)
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                Label("放进 MacBox", systemImage: "tray.and.arrow.down.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}
