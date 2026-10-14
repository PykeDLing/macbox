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
        .searchable(text: $query, placement: .sidebar, prompt: L("搜索应用", "Search Apps"))
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
        .fileDialogMessage(L("选择要放进 MacBox 的应用", "Choose apps to put in MacBox"))
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
        .alert(promptTitle,
               isPresented: Binding(get: { store.prompt != nil }, set: { [id = store.prompt?.id] in
                   // 按显示着的那条的 id 移出：同一次关闭里再置一次 false、或者绑定已经换成下一条时，都不会误关下一条
                   if !$0, let id { store.dismissPrompt(id: id) }
               }),
               presenting: store.prompt) { prompt in
            Button(L("改用虚拟 Mac", "Use Virtual Mac")) { store.box(id: prompt.boxID)?.config.runtime = .virtualMac }
            // 记下这次的拦截：同样的拦截以后不再问，每次退出都弹一次没有意义
            Button(L("继续使用本机隔离", "Keep Native Isolation"), role: .cancel) { store.keepNativeIsolation(prompt) }
        } message: { prompt in
            Text(promptMessage(prompt))
        }
        .alert(L("「\(store.virtualMacOffers.first?.file.lastPathComponent ?? "")」需要在虚拟 Mac 里安装",
                 "“\(store.virtualMacOffers.first?.file.lastPathComponent ?? "")” needs to be installed in the Virtual Mac"),
               isPresented: Binding(get: { !store.virtualMacOffers.isEmpty }, set: { if !$0 { store.dismissVirtualMacOffer() } }),
               presenting: store.virtualMacOffers.first) { offer in
            Button(L("放进虚拟 Mac", "Put in Virtual Mac")) { Task { await store.sendToVirtualMac(offer) } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: { offer in
            Text(offer.message + "\n\n" + L("可以把它放进虚拟 Mac 的「传入」文件夹，在虚拟 Mac 里安装。",
                                             "You can put it in the Virtual Mac’s “传入” (Incoming) folder and install it there."))
        }
        .alert(store.alerts.first?.title ?? "",
               isPresented: Binding(get: { !store.alerts.isEmpty }, set: { if !$0 { store.dismissAlert() } }),
               presenting: store.alerts.first) { _ in
            Button(L("好", "OK")) {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(L("无法添加", "Couldn’t Add App"),
               isPresented: Binding(get: { store.importError != nil }, set: { if !$0 { store.importError = nil } }),
               presenting: store.importError) { _ in
            Button(L("好", "OK")) {}
        } message: { message in
            Text(message)
        }
    }

    private var promptTitle: String {
        let name = store.prompt?.appName ?? ""
        return L("「\(name)」在本机隔离中可能无法正常使用", "“\(name)” may not work properly in Native Isolation")
    }

    private func promptMessage(_ prompt: CompatibilityPrompt) -> String {
        var lines = [prompt.reasons.prefix(4).joined(separator: "\n"),
                     L("改用虚拟 Mac 运行可以获得完整功能。", "Run it in a Virtual Mac to get full functionality.")]
        // 运行时的拦截：选了继续使用本机隔离，同样的拦截以后不再问（见 BoxStore.keepNativeIsolation），要先说清楚
        if !prompt.blocks.isEmpty {
            lines.append(L("选「继续使用本机隔离」后，同样的拦截不再询问。", "If you keep Native Isolation, MacBox won’t ask about these again."))
        }
        return lines.joined(separator: "\n\n")
    }
}

/// 正在退出 MacBox：等应用退出、收尾、维护和添加做完
private struct QuittingBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("正在退出 MacBox…等应用退出、做完收尾后就会退出。", "Quitting MacBox… It will quit once the apps have quit and finished up."))
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
            Section(L("应用", "Apps")) {
                Label(L("全部应用", "All Apps"), systemImage: "square.grid.2x2")
                    .badge(store.boxes.count)
                    .tag(Destination.allApps)
                Label(L("运行中", "Running"), systemImage: "play.circle")
                    .badge(store.runningBoxes.count)
                    .tag(Destination.running)
            }
            Section(L("运行环境", "Runtime")) {
                Label(L("虚拟 Mac", "Virtual Mac"), systemImage: "desktopcomputer")
                    .badge(virtualMacBadge)
                    .tag(Destination.virtualMac)
            }
            Section("MacBox") {
                Label(L("设置", "Settings"), systemImage: "gearshape")
                    .tag(Destination.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Button { importApps() } label: {
                    Label(L("添加应用", "Add App"), systemImage: "plus")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isTerminating)
                .help(L("选择 .dmg、.app、.pkg 或 .zip（⌘O）", "Choose a .dmg, .app, .pkg or .zip (⌘O)"))
                Text(L("也可以把安装包拖进窗口", "Or drop an installer into the window"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var virtualMacBadge: Text? {
        switch virtualMac.status {
        case .notSetUp: Text(L("未设置", "Not Set Up"))
        case .unreadable: Text(L("无法读取", "Unreadable"))
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
                Label(L("放进 MacBox", "Drop into MacBox"), systemImage: "tray.and.arrow.down.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}
