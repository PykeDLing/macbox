import AppKit
import SwiftUI

/// 右侧详情：打开/退出、运行环境、运行报告、网络、文件、还原点
struct BoxInspector: View {
    @Bindable var box: Box
    /// 删除确认由应用页统一处理
    let onDelete: () -> Void
    @Environment(BoxStore.self) private var store
    @Environment(VirtualMac.self) private var virtualMac
    @State private var confirmRestore = false
    @State private var confirmDeleteRestorePoint = false
    @State private var confirmClear = false
    @State private var forceQuitTarget: Box?
    @State private var showAllBlocks = false
    @State private var showReport = false
    @State private var nameDraft = ""
    @State private var dataSize: Int64?

    var body: some View {
        Form {
            header
            banners
            runtimeSection
            if box.config.runtime == .isolated {
                reportSection
                networkSection
                filesSection
                restoreSection
            }
            installerSection
            Section {
                Button(L("删除应用…", "Delete App…"), role: .destructive, action: onDelete)
                    .disabled(box.isRunning || box.isBusy)
            }
        }
        .formStyle(.grouped)
        // 统计占用空间要遍历整个主目录，放到后台。运行开始、结束，以及每次维护（还原、清除数据、完成安装）之后重新统计：
        // 维护都以回到空闲结束。启动、收尾、维护期间 MacBox 自己正在删除、克隆主目录，量出来的数不对，保留上次的
        .task(id: "\(box.isRunning)-\(box.activity == .idle)") {
            guard box.isRunning || box.activity == .idle else { return }
            let size = await box.measureDataSize()
            guard !Task.isCancelled else { return } // 状态又变了：以新的一次为准，旧的结果不再覆盖它
            dataSize = size
        }
        // 重新打开 MacBox 后内存里没有报告：读出最近一次的
        .task(id: box.id) { await box.loadLatestReport() }
        .sheet(isPresented: $showReport) { ReportView(box: box) }
        .forceQuitConfirmation($forceQuitTarget)
        .confirmationDialog(L("还原到还原点？", "Restore to the restore point?"), isPresented: $confirmRestore) {
            Button(L("还原", "Restore"), role: .destructive) {
                perform {
                    try await box.restoreRestorePoint()
                    box.notice = L("已还原。", "Restored.")
                }
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("还原点之后的登录状态、设置和缓存都会丢弃。",
                   "Sign-ins, settings and caches since the restore point will be discarded."))
        }
        .confirmationDialog(L("删除还原点？", "Delete the restore point?"), isPresented: $confirmDeleteRestorePoint) {
            Button(L("删除", "Delete"), role: .destructive) {
                perform {
                    try await box.deleteRestorePoint()
                    box.notice = L("还原点已删除。", "Restore point deleted.")
                }
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(box.config.resetOnQuit
                 ? L("删除后无法再回到这个状态，「每次退出后自动还原」也会关闭。",
                     "You won’t be able to return to this state, and “Restore Automatically After Quitting” will be turned off.")
                 : L("删除后无法再回到这个状态。", "You won’t be able to return to this state."))
        }
        .confirmationDialog(L("清除「\(box.config.name)」的数据？", "Clear data for “\(box.config.name)”?"),
                            isPresented: $confirmClear) {
            Button(L("清除", "Clear"), role: .destructive) {
                perform {
                    try await box.clearData()
                    box.notice = L("数据已清除，下次打开就像刚安装一样。",
                                   "Data cleared. Next time it opens as if freshly installed.")
                }
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(clearDataMessage)
        }
    }

    /// 清除数据不动还原点：还原点里同样有登录状态和钥匙串，之后还能还原回来，要说清楚
    private var clearDataMessage: String {
        var lines = [L("登录状态、设置、缓存和钥匙串都会被清空。应用本身保留。",
                       "Sign-ins, settings, caches and the keychain will be erased. The app itself is kept.")]
        if box.restorePointDate != nil {
            lines.append(box.config.resetOnQuit
                         ? L("还原点不受影响。「每次退出后自动还原」开着，下次退出应用时数据会还原成还原点里的样子。",
                             "The restore point isn’t affected. “Restore Automatically After Quitting” is on, so the data will be restored from it the next time the app quits.")
                         : L("还原点不受影响，之后仍可还原到它。要连同还原点一起删除，请另外删除还原点。",
                             "The restore point isn’t affected; you can still restore to it later. To remove it too, delete the restore point separately."))
        }
        return lines.joined(separator: "\n\n")
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
                    // 回车才保存：改名会重建聚焦里的启动器
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
                        // 经由 open()：主程序已退出、只剩后台程序时，它会让它们退出再重新打开，而不是什么也不做
                        Button { Task { await box.open() } } label: {
                            Label(L("切换过去", "Switch to App"), systemImage: "arrow.up.forward").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        // 「退出」一直都在：应用问要不要存储、你点了取消接着用，之后照样可以再请求退出。
                        // 刚请求过的几秒里不能再点：重复请求会让应用再问一次
                        Button { box.quit() } label: {
                            Text(box.isQuitting ? L("正在退出…", "Quitting…") : L("退出", "Quit")).frame(maxWidth: .infinity)
                        }
                        .disabled(box.isQuitting)
                    } else {
                        Button { Task { await box.open() } } label: {
                            Label(box.config.isInstaller ? L("运行安装器", "Run Installer") : L("打开", "Open"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(box.isBusy || store.isTerminating)
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
                if box.isRunning, box.offersForceQuit {
                    // 请求退出几秒后还在运行：在「退出」之外提供强制退出（先确认）
                    HStack(spacing: 4) {
                        Text(L("还没有退出？", "Still running?")).foregroundStyle(.secondary)
                        Button(L("强制退出…", "Force Quit…")) { forceQuitTarget = box }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .help(L("它可能在等你存储，也可能没有响应。强制退出会丢失没有存储的内容",
                            "It may be waiting for you to save changes, or it may not be responding. Force quitting loses any unsaved changes"))
                }
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

    // MARK: - 运行报告

    /// 这次（或上次）运行的概要，拦截记录可以展开，完整的报告在单独的窗口里
    private var reportSection: some View {
        Section {
            if let report = box.currentReport {
                Text(report.isRunning ? L("正在运行，边运行边记录。", "Running. Recording as it goes.")
                                      : L("上次运行：\(RunReportLabel.time(report))", "Last run: \(RunReportLabel.time(report))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(L("写入文件", "Files Written")) {
                    Text(report.fileTotals.map { L("\($0.count) 个 · \(FileOps.formatBytes($0.bytes))", "\($0.count) · \(FileOps.formatBytes($0.bytes))") }
                         ?? (report.isRunning ? L("退出后统计", "Counted after quitting") : L("没能统计", "Not counted")))
                }
                LabeledContent(L("改动设置", "Settings Changed")) {
                    Text(report.preferenceKeyCount.map { L("\($0) 项", "\($0)") }
                         ?? (report.isRunning ? L("退出后统计", "Counted after quitting") : L("没能统计", "Not counted")))
                }
                LabeledContent(L("连接服务器", "Servers Contacted")) {
                    Text(report.networkBlocked ? L("不联网", "Offline") : L("\(report.servers.count) 个", "\(report.servers.count)"))
                }
                LabeledContent(L("启动程序", "Programs Launched")) {
                    Text(L("\(report.programs.count) 个", "\(report.programs.count)"))
                }
                if !report.blocks.isEmpty { blockRows(report) }
                Button(L("查看完整报告…", "View Full Report…")) { showReport = true }
            } else {
                Text(L("打开应用后，这里会记下它写了哪些文件、改了哪些设置、连了哪些服务器、启动了哪些程序，以及哪些行为被拦下，可以导出分享。",
                       "Once you open the app, this records which files it writes, which settings it changes, which servers it contacts, which programs it launches and what gets blocked. You can export and share it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("运行报告", "Run Report"))
        }
    }

    /// 拦截记录：一行总数，点开逐条列出
    @ViewBuilder
    private func blockRows(_ report: RunReport) -> some View {
        // Form 里的 DisclosureGroup 在 macOS 上点不开，自己做展开行
        Button {
            withAnimation(.easeOut(duration: 0.15)) { showAllBlocks.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(showAllBlocks ? 90 : 0))
                    .font(.caption.weight(.semibold))
                let total = report.blockCount
                Label(report.isRunning
                      ? L("本次已拦截 \(total) 次越界行为",
                          total == 1 ? "Blocked 1 out-of-bounds attempt this session" : "Blocked \(total) out-of-bounds attempts this session")
                      : L("拦截了 \(total) 次越界行为", total == 1 ? "Blocked 1 out-of-bounds attempt" : "Blocked \(total) out-of-bounds attempts"),
                      systemImage: "hand.raised.fill")
                Spacer()
            }
            .contentShape(Rectangle())
            .foregroundStyle(report.blocks.contains(where: \.kind.suggestsVirtualMac) ? .orange : .secondary)
        }
        .buttonStyle(.plain)
        if showAllBlocks {
            ForEach(report.blocks) { block in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(block.kind.title)\(block.count > 1 ? " ×\(block.count)" : "")")
                        .font(.callout)
                    Text(block.targetText).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 网络

    private var networkSection: some View {
        Section(L("网络", "Network")) {
            Toggle(L("允许联网", "Allow Network Access"), isOn: $box.config.allowsNetwork)
                .disabled(box.isRunning || box.isBusy)
            Text(networkCaption)
                .font(.caption)
                .foregroundStyle(box.config.isInstaller && !box.config.allowsNetwork ? .orange : .secondary)
        }
    }

    private var networkCaption: String {
        if box.config.allowsNetwork {
            return L("关掉后，应用连不上任何服务器，在本机上的代理也连不上。下次打开时生效。",
                     "When off, the app can’t reach any server, not even a proxy on this Mac. Takes effect the next time it opens.")
        }
        if box.config.isInstaller {
            return L("在线安装器要联网才能下载安装包，不联网时它装不了。",
                     "Online installers need the network to download the installer package, so this one can’t install while offline.")
        }
        return L("应用连不上任何服务器，在本机上的代理也连不上；它显示的网页也打不开，用网页做的界面会是空白。登录、同步、更新都用不了。",
                 "The app can’t reach any server, not even a proxy on this Mac. Web pages it shows won’t load either, so parts built from web pages stay blank. Signing in, syncing and updates won’t work.")
    }

    // MARK: - 安装器、聚焦

    /// 是不是在线安装器由文件名、大小猜出来，会猜错（下载器、卸载工具……）：让用户自己改。
    /// 只有本机隔离会接手安装；在虚拟 Mac 里运行时安装在虚拟 Mac 里完成，这个开关不起作用，不显示
    private var installerSection: some View {
        Section {
            if box.config.runtime == .isolated {
                Toggle(L("在线安装器", "Online Installer"), isOn: $box.config.isInstaller)
                    .disabled(box.isRunning || box.isBusy)
                Text(box.config.isInstaller
                     ? L("运行后会下载完整的安装包，MacBox 取出里面的 App 完成安装。如果这就是应用本身，请关掉。",
                         "When it runs, it downloads the full installer package, and MacBox finishes the installation with the app inside. If this is the app itself, turn this off.")
                     : L("如果这是一个运行后才下载完整安装包的小安装器，请打开，由 MacBox 接手安装。",
                         "If this is a small installer that downloads the full package when it runs, turn this on so MacBox can take over the installation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let waitsForInstall = box.config.isInstaller && box.config.runtime == .isolated
            Toggle(L("在聚焦中显示", "Show in Spotlight"), isOn: $box.config.showInLaunchpad)
                .disabled(waitsForInstall)
                .help(L("在 ~/Applications/MacBox 放一个启动器，像普通 App 一样打开",
                        "Put a launcher in ~/Applications/MacBox so you can open it like any other app"))
            if waitsForInstall {
                Text(L("安装器没有启动器。安装完成后，启动器会按这里的设置创建。",
                       "Installers don’t get a launcher. Once the installation finishes, one is created according to this setting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 文件

    private var filesSection: some View {
        Section(L("文件", "Files")) {
            Toggle(L("共享「下载」文件夹", "Share Downloads Folder"), isOn: $box.config.shareDownloads)
                .disabled(box.isRunning || box.isBusy)
            Text(box.config.shareDownloads
                 ? L("应用下载的文件直接保存到你的「下载」文件夹，删除应用后仍然保留；它也能修改、删除那里的文件。",
                     "Files the app downloads are saved directly to your Downloads folder and stay there after you delete the app. The app can also change or delete files there.")
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
                LabeledContent(L("创建于", "Created")) {
                    HStack(spacing: 6) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                        // 放在这一行而不是下面的按钮行：英文的按钮名较长，三个按钮并排放不下
                        Button(role: .destructive) { confirmDeleteRestorePoint = true } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(L("删除还原点…", "Delete Restore Point…"))
                        .accessibilityLabel(L("删除还原点", "Delete Restore Point"))
                        .disabled(box.isRunning || box.isBusy)
                    }
                }
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
