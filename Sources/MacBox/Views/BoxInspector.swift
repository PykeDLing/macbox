import AppKit
import SwiftUI

/// 右侧详情：打开/退出、运行环境、文件、还原点
struct BoxInspector: View {
    @Bindable var box: Box
    /// 删除确认由应用页统一处理
    let onDelete: () -> Void
    @Environment(BoxStore.self) private var store
    @Environment(VirtualMac.self) private var virtualMac
    @State private var confirmRestore = false
    @State private var confirmClear = false
    @State private var showAllBlocks = false
    @State private var nameDraft = ""
    @State private var dataSize: Int64?
    /// 清除数据、还原后递增，触发重新统计占用空间
    @State private var dataRevision = 0

    var body: some View {
        Form {
            header
            banners
            runtimeSection
            if box.config.runtime == .isolated {
                filesSection
                restoreSection
            }
            Section {
                Toggle(L("在启动台和聚焦中显示", "Show in Launchpad and Spotlight"), isOn: $box.config.showInLaunchpad)
                    .help(L("在 ~/Applications/MacBox 放一个启动器，像普通 App 一样打开",
                            "Put a launcher in ~/Applications/MacBox so you can open it like any other app"))
                Button(L("删除应用…", "Delete App…"), role: .destructive, action: onDelete)
                    .disabled(box.isRunning || box.isBusy)
            }
        }
        .formStyle(.grouped)
        // 统计占用空间要遍历整个主目录，放到后台，运行状态变化或数据变动后重新统计
        .task(id: "\(box.isRunning)-\(dataRevision)") {
            dataSize = await box.measureDataSize()
        }
        .confirmationDialog(L("还原到还原点？", "Restore to Restore Point?"), isPresented: $confirmRestore) {
            Button(L("还原", "Restore"), role: .destructive) {
                perform {
                    try await box.restoreRestorePoint()
                    box.notice = L("已还原。", "Restored.")
                    dataRevision += 1
                }
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("还原点之后的登录状态、设置和缓存都会丢弃。",
                   "Sign-ins, settings and caches since the restore point will be discarded."))
        }
        .confirmationDialog(L("清除「\(box.config.name)」的数据？", "Clear Data for “\(box.config.name)”?"),
                            isPresented: $confirmClear) {
            Button(L("清除", "Clear"), role: .destructive) {
                perform {
                    try await box.clearData()
                    box.notice = L("数据已清除，下次打开就像刚安装一样。",
                                   "Data cleared. Next time it opens as if freshly installed.")
                    dataRevision += 1
                }
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("登录状态、设置、缓存和钥匙串都会被清空。应用本身保留。",
                   "Sign-ins, settings, caches and the keychain will be erased. The app itself is kept."))
        }
    }

    // MARK: - 头部

    private var header: some View {
        Section {
            VStack(spacing: 10) {
                Image(nsImage: box.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                VStack(spacing: 3) {
                    // 回车才保存：改名会重建启动台里的启动器
                    TextField(L("名称", "Name"), text: $nameDraft)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .help(L("点击修改名称，按回车保存", "Click to rename, press Return to save"))
                        .onSubmit {
                            let name = nameDraft.trimmingCharacters(in: .whitespaces)
                            if name.isEmpty { nameDraft = box.config.name } else { box.config.name = name }
                        }
                        .onAppear { nameDraft = box.config.name }
                        .onChange(of: box.config.name) { nameDraft = box.config.name }
                    Text([box.config.version.map { L("版本 \($0)", "Version \($0)") }, box.config.bundleIdentifier]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    BoxStatusTag(box: box).padding(.top, 2)
                }
                HStack(spacing: 8) {
                    if box.isRunning {
                        Button { box.session?.activate() } label: {
                            Label(L("切换过去", "Switch to App"), systemImage: "arrow.up.forward").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { box.quit() } label: { Text(L("退出", "Quit")).frame(maxWidth: .infinity) }
                    } else {
                        Button { Task { await box.open() } } label: {
                            Label(box.config.isInstaller ? L("运行安装器", "Run Installer") : L("打开", "Open"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(box.isBusy)
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if box.lastError != nil || box.notice != nil {
            Section {
                if let error = box.lastError {
                    Banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red) { box.lastError = nil }
                }
                if let notice = box.notice {
                    Banner(text: notice, systemImage: "info.circle.fill", tint: .blue) { box.notice = nil }
                }
            }
        }
    }

    // MARK: - 运行环境

    private var runtimeSection: some View {
        Section {
            Picker(L("运行环境", "Runtime"), selection: $box.config.runtime) {
                ForEach(Runtime.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(box.isRunning || box.isBusy)
            Text(box.config.runtime.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(box.config.issues) { issue in
                IssueRow(issue: issue)
            }

            if box.config.runtime == .isolated {
                if !box.blocks.isEmpty {
                    // Form 里的 DisclosureGroup 在 macOS 上点不开，自己做展开行
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showAllBlocks.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showAllBlocks ? 90 : 0))
                                .font(.caption.weight(.semibold))
                            let total = box.blocks.reduce(0) { $0 + $1.count }
                            Label(L("本次已拦截 \(total) 次越界行为",
                                    total == 1 ? "Blocked 1 out-of-bounds attempt this session"
                                               : "Blocked \(total) out-of-bounds attempts this session"),
                                  systemImage: "hand.raised.fill")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .foregroundStyle(box.blocks.contains(where: \.kind.suggestsVirtualMac) ? .orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    if showAllBlocks {
                        ForEach(box.blocks) { block in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(block.kind.title)\(block.count > 1 ? " ×\(block.count)" : "")")
                                    .font(.callout)
                                Text(block.target).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }
                }
                Button(L("软件不正常？改用虚拟 Mac 运行", "Not working right? Run in Virtual Mac instead")) { box.config.runtime = .virtualMac }
                    .buttonStyle(.link)
                    .disabled(box.isRunning || box.isBusy)
            } else {
                if !virtualMac.config.installed {
                    Label(L("虚拟 Mac 还没有设置。第一次需要下载约 18 GB 的 macOS 并安装，之后所有需要它的应用共用一台。",
                            "Virtual Mac isn’t set up yet. The first setup downloads and installs about 18 GB of macOS; after that, every app that needs it shares the same one."),
                          systemImage: "info.circle")
                        .font(.caption)
                    Button(L("前往设置虚拟 Mac…", "Set Up Virtual Mac…")) { store.show(.virtualMac) }
                } else {
                    Text(L("打开后，原始安装文件会放进虚拟 Mac 的「传入」文件夹（访达 › 位置 › My Shared Files），在里面安装一次即可。",
                            "When you open it, the original installer is placed in the Virtual Mac’s “传入” (Incoming) folder (Finder › Locations › My Shared Files). Install it from there once."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("运行环境", "Runtime"))
        }
    }

    // MARK: - 文件

    private var filesSection: some View {
        Section(L("文件", "Files")) {
            Toggle(L("共享「下载」文件夹", "Share Downloads Folder"), isOn: $box.config.shareDownloads)
                .disabled(box.isRunning || box.isBusy)
            Text(box.config.shareDownloads
                 ? L("应用下载的文件直接保存到你的「下载」文件夹。",
                     "Files the app downloads are saved directly to your Downloads folder.")
                 : L("应用只能看到盒子里自己的「下载」文件夹。",
                     "The app can only see its own Downloads folder inside the box."))
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent(L("应用数据", "App Data")) {
                if let dataSize { Text(FileOps.formatBytes(dataSize)) } else { ProgressView().controlSize(.small) }
            }
            HStack {
                Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([box.paths.home]) }
                Spacer()
                Button(L("清除数据…", "Clear Data…")) { confirmClear = true }
                    .disabled(box.isRunning || box.isBusy)
            }
        }
    }

    // MARK: - 还原点

    private var restoreSection: some View {
        Section(L("还原点", "Restore Point")) {
            if let date = box.restorePointDate {
                LabeledContent(L("创建于", "Created"), value: date.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text(L("创建一个还原点，之后可以随时回到这个状态（比如刚登录好的时候）。",
                        "Create a restore point to return to this state at any time (for example, right after signing in)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(box.restorePointDate == nil ? L("创建还原点", "Create Restore Point") : L("更新还原点", "Update Restore Point")) {
                    perform {
                        try await box.createRestorePoint()
                        box.notice = L("还原点已创建。", "Restore point created.")
                    }
                }
                Button(L("还原…", "Restore…")) { confirmRestore = true }
                    .disabled(box.restorePointDate == nil)
            }
            .disabled(box.isRunning || box.isBusy)
            Toggle(L("每次退出后自动还原", "Restore Automatically After Quitting"), isOn: $box.config.resetOnQuit)
                .disabled(box.restorePointDate == nil)
        }
    }

    /// 还原点、清除数据都在后台做文件操作，期间 box.isBusy 为真
    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { box.lastError = error.localizedDescription }
        }
    }
}

private struct IssueRow: View {
    let issue: CompatibilityIssue

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.localizedTitle).font(.callout)
                Text(issue.localizedDetail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
    }

    private var icon: String {
        switch issue.severity {
        case .needsVirtualMac: "exclamationmark.triangle.fill"
        case .limited: "minus.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch issue.severity {
        case .needsVirtualMac: .orange
        case .limited: .yellow
        case .info: .secondary
        }
    }
}
