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
    @State private var forceQuitTarget: Box?
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
                            Label("未选择应用", systemImage: "cursorarrow.click.2")
                        } description: {
                            Text("单击卡片查看详情，双击打开。\n右键可以切换运行环境或删除。")
                        }
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
            }
            .toolbar {
                if !store.boxes.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInspector.toggle() } label: { Label("详情", systemImage: "sidebar.right") }
                            .help(showInspector ? String(localized: "隐藏详情") : String(localized: "显示详情"))
                    }
                }
            }
            .navigationTitle(runningOnly ? String(localized: "运行中") : String(localized: "全部应用"))
            .navigationSubtitle(subtitle)
            .onAppear { if store.selection == nil { store.selection = visibleBoxes.first?.id } }
            .confirmationDialog(pendingDelete?.title ?? "", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { target in
                Button("移到废纸篓", role: .destructive) { delete(target) }
                Button("取消", role: .cancel) {}
            } message: { target in
                Text(target.message)
            }
            .forceQuitConfirmation($forceQuitTarget)
            .alert("无法删除", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
                   presenting: actionError) { _ in
                Button("好") {}
            } message: { Text($0) }
    }

    private var subtitle: String {
        let running = store.runningBoxes.count
        let total = store.boxes.count
        let runningText = String(localized: "\(running) 个应用正在运行")
        if runningOnly { return running > 0 ? runningText : "" }
        let totalText = String(localized: "\(total) 个应用")
        return running > 0 ? String(localized: "\(totalText) · \(running) 个运行中") : totalText
    }

    @ViewBuilder
    private var content: some View {
        if store.boxes.isEmpty && store.brokenBoxes.isEmpty && store.importStatus == nil {
            WelcomeView()
        } else if visibleBoxes.isEmpty && visibleBroken.isEmpty && store.importStatus == nil {
            if !query.isEmpty {
                ContentUnavailableView(String(localized: "没有“\(query)”的结果"),
                                       systemImage: "magnifyingglass",
                                       description: Text("请检查拼写或换个关键词。"))
            } else {
                ContentUnavailableView {
                    Label("没有正在运行的应用", systemImage: "play.circle")
                } description: {
                    Text("在「全部应用」里双击一个应用即可打开。")
                } actions: {
                    Button("查看全部应用") { store.destination = .allApps }
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
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([broken.url]) }
                                Divider()
                                Button("删除…", role: .destructive) { pendingDelete = .broken(broken) }
                            }
                    }
                    if let status = store.importStatus {
                        ImportingCard(status: status)
                    } else if !runningOnly && query.isEmpty {
                        AddCard { importApps() }
                            .disabled(store.isTerminating)
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
            .accessibilityAction(named: box.isRunning ? String(localized: "切换过去") : String(localized: "打开")) { Task { await box.open() } }
    }

    @ViewBuilder
    private func cardMenu(_ box: Box) -> some View {
        Button(box.isRunning ? String(localized: "切换到「\(box.config.name)」") : String(localized: "打开")) {
            Task { await box.open() }
        }
        .disabled(store.isTerminating && !box.isRunning) // 正在退出 MacBox：不再打开，切换过去照样可以
        if box.isRunning {
            // 「退出」一直都在（刚请求过的几秒里不能再点）；请求几秒后还在运行时，下面再加一项强制退出（先确认）
            Button(box.isQuitting ? String(localized: "正在退出…") : String(localized: "退出")) { box.quit() }
                .disabled(box.isQuitting)
            if box.offersForceQuit {
                Button("强制退出…") { forceQuitTarget = box }
            }
        }
        Divider()
        Picker("运行环境", selection: Binding(get: { box.config.runtime }, set: { box.config.runtime = $0 })) {
            ForEach(Runtime.allCases) { Text($0.title).tag($0) }
        }
        .disabled(box.isRunning || box.isBusy)
        Button("在访达中显示应用数据") { NSWorkspace.shared.activateFileViewerSelecting([box.paths.home]) }
        Divider()
        Button("删除…", role: .destructive) {
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
        Task {
            do {
                switch target {
                case .box(let box): try await store.delete(box) // 先收回没收回的偏好设置，期间卡片显示“处理中”
                case .broken(let broken): try store.deleteBroken(broken)
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private enum DeleteTarget {
    case box(Box)
    case broken(BrokenBox)

    var title: String {
        switch self {
        case .box(let box): String(localized: "删除「\(box.config.name)」？")
        case .broken: String(localized: "删除这个无法读取的应用？")
        }
    }

    var message: String {
        switch self {
        // 共享「下载」时（默认），它存进你「下载」里的文件不在盒子里，不会跟着删除；可以写入的文件夹同理
        case .box(let box) where box.config.shareDownloads && !box.config.writableFolderPaths.isEmpty:
            String(localized: "应用和它的全部数据（设置、缓存、钥匙串）会一起移到废纸篓。它存进你「下载」和它可以写入的文件夹里的文件不在盒子里，会保留。")
        case .box(let box) where box.config.shareDownloads:
            String(localized: "应用和它的全部数据（设置、缓存、钥匙串）会一起移到废纸篓。它存进你「下载」文件夹的文件不在盒子里，会保留。")
        case .box(let box) where !box.config.writableFolderPaths.isEmpty:
            String(localized: "应用和它的全部数据（设置、缓存、钥匙串）会一起移到废纸篓。它存进它可以写入的文件夹里的文件不在盒子里，会保留。")
        case .box: String(localized: "应用和它的全部数据（设置、缓存、钥匙串）会一起移到废纸篓。")
        case .broken: String(localized: "它的文件夹会移到废纸篓，需要时可以从废纸篓里找回。")
        }
    }
}

// MARK: - 卡片

private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
private let cardHeight: CGFloat = 158

struct AppCard: View {
    let box: Box
    let isSelected: Bool
    @Environment(BoxStore.self) private var store
    @State private var hovering = false
    /// 正在退出 MacBox：打开不会生效，只给运行中的显示（切换过去）按钮
    private var terminating: Bool { store.isTerminating }

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
            if hovering && !box.isBusy && (box.isRunning || !terminating) { openButton.transition(.opacity) }
        }
        .contentShape(cardShape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(box.isRunning ? String(localized: "双击切换到「\(box.config.name)」")
                             : String(localized: "双击打开"))
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
        .help(box.isRunning ? String(localized: "切换过去") : (box.config.isInstaller ? String(localized: "运行安装器") : String(localized: "打开")))
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
            (title, symbol, color) = if box.isQuitting {
                (String(localized: "正在退出…"), "hourglass", .secondary)
            } else if box.isRunning {
                (String(localized: "运行中"), "circle.fill", .green)
            } else if box.isBusy {
                (String(localized: "处理中…"), "hourglass", .secondary)
            } else if box.config.runtime == .virtualMac {
                (String(localized: "虚拟 Mac"), "desktopcomputer", .secondary)
            } else if box.cannotRunNatively {
                (String(localized: "需要虚拟 Mac"), "exclamationmark.triangle.fill", .orange)
            } else if box.worstIssue == .needsVirtualMac || box.blocks.contains(where: \.kind.suggestsVirtualMac) {
                (String(localized: "可能需要虚拟 Mac"), "exclamationmark.triangle.fill", .orange)
            } else if box.config.isInstaller {
                (String(localized: "安装器"), "shippingbox", .secondary)
            } else if !box.config.allowsNetwork {
                (String(localized: "本机隔离 · 不联网"), "network.slash", Color.secondary.opacity(0.8))
            } else {
                (String(localized: "本机隔离"), "lock.fill", Color.secondary.opacity(0.8))
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
                Text("无法读取").font(.system(size: 13, weight: .medium))
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
        .help("\(broken.message)\n右键可以在访达中查看或删除")
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
                Text("添加应用").font(.system(size: 13, weight: .medium))
                Text("点击选择或拖入安装包").font(.caption).foregroundStyle(.secondary)
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
                    FeatureCard(icon: "folder.badge.person.crop", title: String(localized: "数据留在盒子里"),
                                text: String(localized: "设置、缓存、登录状态都存在 MacBox，删除应用即清空。"))
                    FeatureCard(icon: "key.fill", title: String(localized: "独立的钥匙串"),
                                text: String(localized: "应用保存的密码不会写进你的「登录」钥匙串。"))
                    FeatureCard(icon: "desktopcomputer", title: String(localized: "虚拟 Mac 兜底"),
                                text: String(localized: "需要驱动或系统服务的应用，可以放进虚拟 Mac 运行。"))
                }
                Button("了解更多隔离细节，或调整偏好设置 →") { store.destination = .settings }
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
            Text("把下载的安装包拖到这里").font(.title2.weight(.semibold))
            Text("MacBox 会把应用装进一个独立的盒子。你照常使用，\n它写下的文件、设置和钥匙串都不会留在你的 Mac 上。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { importApps() } label: {
                Text("选择文件…").frame(minWidth: 120)
            }
            .disabled(store.isTerminating)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            Text("支持 .dmg · .app · .pkg · .zip")
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
