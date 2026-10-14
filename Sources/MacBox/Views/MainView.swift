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
        .focusedSceneValue(\.importApps, ImportAppsAction(isPresented: $importing))
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
        .alert(L("「\(store.prompt?.appName ?? "")」在本机隔离中可能无法正常使用",
                 "“\(store.prompt?.appName ?? "")” may not work properly in Native Isolation"),
               isPresented: Binding(get: { store.prompt != nil }, set: { if !$0 { store.prompt = nil } }),
               presenting: store.prompt) { prompt in
            Button(L("改用虚拟 Mac", "Use Virtual Mac")) { store.box(id: prompt.boxID)?.config.runtime = .virtualMac }
            Button(L("继续使用本机隔离", "Keep Native Isolation"), role: .cancel) {}
        } message: { prompt in
            Text(prompt.reasons.prefix(4).joined(separator: "\n") + "\n\n"
                 + L("改用虚拟 Mac 运行可以获得完整功能。", "Run it in a Virtual Mac to get full functionality."))
        }
        .alert(L("无法添加", "Couldn’t Add App"),
               isPresented: Binding(get: { store.importError != nil }, set: { if !$0 { store.importError = nil } }),
               presenting: store.importError) { _ in
            Button(L("好", "OK")) {}
        } message: { message in
            Text(message)
        }
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
        case .stopped: virtualMac.isAsleep ? Text(L("睡眠", "Asleep")) : nil
        default: Text(virtualMac.status.title)
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
