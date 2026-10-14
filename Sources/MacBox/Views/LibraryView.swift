import AppKit
import SwiftUI

/// 应用页：装进 MacBox 的应用排成卡片，右侧是选中应用的详情
struct LibraryView: View {
    let runningOnly: Bool
    let query: String
    @Environment(BoxStore.self) private var store
    @Environment(\.importApps) private var importApps
    @SceneStorage("library.showInspector") private var showInspector = true
    @State private var pendingDelete: DeleteTarget?
    @State private var actionError: String?
    @State private var gridWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool

    private let minCardWidth: CGFloat = 148
    private let spacing: CGFloat = 14
    private let padding: CGFloat = 20
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: minCardWidth, maximum: 190), spacing: spacing)] }
    /// 与 adaptive 网格的排法一致，用于上下方向键跨行移动
    private var columnCount: Int { max(1, Int((gridWidth - padding * 2 + spacing) / (minCardWidth + spacing))) }

    private var visibleBoxes: [Box] {
        store.boxes.filter { box in
            (!runningOnly || box.isRunning)
                && (query.isEmpty || box.config.name.localizedCaseInsensitiveContains(query))
        }
    }

    private var visibleBroken: [BrokenBox] { runningOnly || !query.isEmpty ? [] : store.brokenBoxes }
    private var selectedBox: Box? { store.selection.flatMap { id in visibleBoxes.first { $0.id == id } } }

    var body: some View {
        content
            // 还没有应用时（第一次使用）不显示空白的详情栏
            .inspector(isPresented: Binding(get: { showInspector && !store.boxes.isEmpty }, set: { showInspector = $0 })) {
                Group {
                    if let box = selectedBox {
                        BoxInspector(box: box) { pendingDelete = .box(box) }.id(box.id)
                    } else {
                        ContentUnavailableView {
                            Label(L("未选择应用", "No App Selected"), systemImage: "cursorarrow.click.2")
                        } description: {
                            Text(L("单击卡片查看详情，双击打开。\n右键可以切换运行环境或删除。",
                                 "Click a card to see details, double-click to open it.\nRight-click to change the runtime or delete."))
                        }
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
            }
            .toolbar {
                if !store.boxes.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: { Label(L("详情", "Details"), systemImage: "sidebar.right") }
                            .help(showInspector ? L("隐藏详情", "Hide Details") : L("显示详情", "Show Details"))
                    }
                }
            }
            .navigationTitle(runningOnly ? L("运行中", "Running") : L("全部应用", "All Apps"))
            .navigationSubtitle(subtitle)
            .onAppear { if store.selection == nil { store.selection = visibleBoxes.first?.id } }
            .confirmationDialog(pendingDelete?.title ?? "", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { target in
                Button(L("移到废纸篓", "Move to Trash"), role: .destructive) { delete(target) }
                Button(L("取消", "Cancel"), role: .cancel) {}
            } message: { target in
                Text(target.message)
            }
            .alert(L("无法删除", "Couldn’t Delete"), isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
                   presenting: actionError) { _ in
                Button(L("好", "OK")) {}
            } message: { Text($0) }
    }

    private var subtitle: String {
        let running = store.runningBoxes.count
        let total = store.boxes.count
        let runningText = L("\(running) 个应用正在运行", running == 1 ? "1 app running" : "\(running) apps running")
        if runningOnly { return running > 0 ? runningText : "" }
        let totalText = L("\(total) 个应用", total == 1 ? "1 app" : "\(total) apps")
        return running > 0 ? L("\(total) 个应用 · \(running) 个运行中", "\(totalText) · \(running) running") : totalText
    }

    @ViewBuilder
    private var content: some View {
        if store.boxes.isEmpty && store.brokenBoxes.isEmpty && store.importStatus == nil {
            WelcomeView()
        } else if visibleBoxes.isEmpty && visibleBroken.isEmpty && store.importStatus == nil {
            if !query.isEmpty {
                ContentUnavailableView(L("没有“\(query)”的结果", "No Results for “\(query)”"),
                                       systemImage: "magnifyingglass",
                                       description: Text(L("请检查拼写或换个关键词。", "Check the spelling or try a new search.")))
            } else {
                ContentUnavailableView {
                    Label(L("没有正在运行的应用", "No Apps Running"), systemImage: "play.circle")
                } description: {
                    Text(L("在「全部应用」里双击一个应用即可打开。", "Double-click an app in “All Apps” to open it."))
                } actions: {
                    Button(L("查看全部应用", "Show All Apps")) { store.destination = .allApps }
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(visibleBoxes) { box in
                        card(for: box)
                    }
                    ForEach(visibleBroken) { broken in
                        BrokenCard(broken: broken)
                            .contextMenu {
                                Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([broken.url]) }
                                Divider()
                                Button(L("删除…", "Delete…"), role: .destructive) { pendingDelete = .broken(broken) }
                            }
                    }
                    if let status = store.importStatus {
                        ImportingCard(status: status)
                    } else if !runningOnly && query.isEmpty {
                        AddCard { importApps() }
                    }
                }
                .padding(padding)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { store.selection = nil } }
            // 键盘：方向键移动选择，回车打开，Delete 删除
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: moveSelection)
            .onKeyPress(.return) {
                guard let box = selectedBox else { return .ignored }
                Task { await box.open() }
                return .handled
            }
            .onDeleteCommand { if let box = selectedBox, !box.isRunning { pendingDelete = .box(box) } }
        }
    }

    private func card(for box: Box) -> some View {
        AppCard(box: box, isSelected: store.selection == box.id)
            .onTapGesture(count: 2) { Task { await box.open() } }
            .simultaneousGesture(TapGesture().onEnded {
                store.selection = box.id
                gridFocused = true
            })
            .contextMenu { cardMenu(box) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(box.config.name)
            .accessibilityValue(BoxStatusTag.State(box).title)
            .accessibilityAddTraits(store.selection == box.id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { store.selection = box.id }
            .accessibilityAction(named: box.isRunning ? L("切换过去", "Switch to App") : L("打开", "Open")) { Task { await box.open() } }
    }

    @ViewBuilder
    private func cardMenu(_ box: Box) -> some View {
        Button(box.isRunning ? L("切换到「\(box.config.name)」", "Switch to “\(box.config.name)”") : L("打开", "Open")) {
            Task { await box.open() }
        }
        if box.isRunning { Button(L("退出", "Quit")) { box.quit() } }
        Divider()
        Picker(L("运行环境", "Runtime"), selection: Binding(get: { box.config.runtime }, set: { box.config.runtime = $0 })) {
            ForEach(Runtime.allCases) { Text($0.title).tag($0) }
        }
        .disabled(box.isRunning)
        Button(L("在访达中显示应用数据", "Show App Data in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([box.paths.home]) }
        Divider()
        Button(L("删除…", "Delete…"), role: .destructive) {
            store.selection = box.id
            pendingDelete = .box(box)
        }
        .disabled(box.isRunning || box.isBusy)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let ids = visibleBoxes.map(\.id)
        guard !ids.isEmpty else { return }
        let step = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columnCount
        case .down: columnCount
        @unknown default: 0
        }
        let current = store.selection.flatMap { ids.firstIndex(of: $0) }
        store.selection = ids[current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0]
    }

    private func delete(_ target: DeleteTarget) {
        do {
            switch target {
            case .box(let box): try store.delete(box)
            case .broken(let broken): try store.deleteBroken(broken)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private enum DeleteTarget {
    case box(Box)
    case broken(BrokenBox)

    var title: String {
        switch self {
        case .box(let box): L("删除「\(box.config.name)」？", "Delete “\(box.config.name)”?")
        case .broken: L("删除这个无法读取的应用？", "Delete this unreadable app?")
        }
    }

    var message: String {
        switch self {
        case .box: L("应用和它的全部数据（设置、缓存、钥匙串）会一起移到废纸篓，你的 Mac 上不会留下任何东西。",
                      "The app and all its data (settings, caches, keychain) will be moved to the Trash. Nothing will be left behind on your Mac.")
        case .broken: L("它的文件夹会移到废纸篓，需要时可以从废纸篓里找回。",
                        "Its folder will be moved to the Trash, where you can recover it if needed.")
        }
    }
}

// MARK: - 卡片

private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
private let cardHeight: CGFloat = 158

struct AppCard: View {
    let box: Box
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: box.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
                .opacity(box.isBusy ? 0.45 : 1)
                .overlay { if box.isBusy { ProgressView().controlSize(.small) } }
            VStack(spacing: 4) {
                Text(box.config.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                BoxStatusTag(box: box)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .background(cardShape.fill(isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .overlay(cardShape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if hovering && !box.isBusy { openButton.transition(.opacity) }
        }
        .contentShape(cardShape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(box.isRunning ? L("双击切换到「\(box.config.name)」", "Double-click to switch to “\(box.config.name)”")
                             : L("双击打开", "Double-click to open"))
    }

    private var openButton: some View {
        Button { Task { await box.open() } } label: {
            Image(systemName: box.isRunning ? "arrow.up.forward" : "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(box.isRunning ? L("切换过去", "Switch to App") : (box.config.isInstaller ? L("运行安装器", "Run Installer") : L("打开", "Open")))
        .padding(8)
    }
}

/// 卡片和详情栏共用的状态标签
struct BoxStatusTag: View {
    let box: Box

    var body: some View {
        let state = State(box)
        HStack(spacing: 4) {
            Image(systemName: state.symbol).font(.system(size: state.symbol == "circle.fill" ? 6 : 9, weight: .semibold))
            Text(state.title)
        }
        .font(.caption)
        .foregroundStyle(state.color)
        .lineLimit(1)
    }

    struct State {
        let title: String
        let symbol: String
        let color: Color

        init(_ box: Box) {
            (title, symbol, color) = if box.isRunning {
                (L("运行中", "Running"), "circle.fill", .green)
            } else if box.isBusy {
                (L("处理中…", "Working…"), "hourglass", .secondary)
            } else if box.config.runtime == .virtualMac {
                (L("虚拟 Mac", "Virtual Mac"), "desktopcomputer", .secondary)
            } else if box.worstIssue == .needsVirtualMac || box.blocks.contains(where: \.kind.suggestsVirtualMac) {
                (L("可能需要虚拟 Mac", "May Need Virtual Mac"), "exclamationmark.triangle.fill", .orange)
            } else if box.config.isInstaller {
                (L("安装器", "Installer"), "shippingbox", .secondary)
            } else {
                (L("本机隔离", "Native Isolation"), "lock.fill", Color.secondary.opacity(0.8))
            }
        }
    }
}

/// 配置文件读不出来的盒子：只读展示，可以在访达中查看或删除
private struct BrokenCard: View {
    let broken: BrokenBox

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .frame(width: 72, height: 72)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 4) {
                Text(L("无法读取", "Unreadable")).font(.system(size: 13, weight: .medium))
                Text(broken.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .background(cardShape.fill(Color.orange.opacity(0.05)))
        .overlay(cardShape.strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .help(L("\(broken.message)\n右键可以在访达中查看或删除",
                 "\(broken.message)\nRight-click to show in Finder or delete"))
        .accessibilityElement(children: .combine)
    }
}

private struct AddCard: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(hovering ? 0.2 : 0.12), in: Circle())
                    .foregroundStyle(.tint)
                Text(L("添加应用", "Add App")).font(.system(size: 13, weight: .medium))
                Text(L("点击选择或拖入安装包", "Click to choose, or drop an installer")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight)
            .background(cardShape.fill(Color.primary.opacity(hovering ? 0.04 : 0)))
            .overlay(cardShape.strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.14), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(cardShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ImportingCard: View {
    let status: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large).frame(width: 72, height: 72)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .background(cardShape.fill(Color.accentColor.opacity(0.06)))
        .overlay(cardShape.strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - 第一次使用

private struct WelcomeView: View {
    @Environment(BoxStore.self) private var store
    @Environment(\.importApps) private var importApps

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                dropZone
                HStack(alignment: .top, spacing: 12) {
                    FeatureCard(icon: "folder.badge.person.crop", title: L("数据留在盒子里", "Data Stays in the Box"),
                                text: L("设置、缓存、登录状态都存在 MacBox，删除应用即清空。",
                                        "Settings, caches and sign-ins live in MacBox. Delete the app and they’re gone."))
                    FeatureCard(icon: "key.fill", title: L("独立的钥匙串", "Separate Keychain"),
                                text: L("应用保存的密码不会写进你的「登录」钥匙串。",
                                        "Passwords the app saves never go into your “login” keychain."))
                    FeatureCard(icon: "desktopcomputer", title: L("虚拟 Mac 兜底", "Virtual Mac Fallback"),
                                text: L("需要驱动或系统服务的应用，可以放进虚拟 Mac 运行。",
                                        "Apps that need drivers or system services can run in a Virtual Mac."))
                }
                Button(L("了解更多隔离细节，或调整偏好设置 →", "Learn more about isolation, or adjust preferences →")) { store.destination = .settings }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            .frame(maxWidth: 680)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 10, y: 4)
            Text(L("把下载的安装包拖到这里", "Drop a Downloaded Installer Here")).font(.title2.weight(.semibold))
            Text(L("MacBox 会把应用装进一个独立的盒子。你照常使用，\n它写下的文件、设置和钥匙串都不会留在你的 Mac 上。",
                    "MacBox installs the app in its own box. Use it as usual —\nthe files, settings and keychain items it writes never stay on your Mac."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { importApps() } label: {
                Text(L("选择文件…", "Choose Files…")).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            Text(L("支持 .dmg · .app · .pkg · .zip", "Supports .dmg · .app · .pkg · .zip"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}
