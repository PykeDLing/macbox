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
    /// 拦截记录旁点了「允许写入」、等确认的文件夹
    @State private var allowTarget: String?
    /// 拦截记录旁点了「共享「下载」…」、等确认
    @State private var confirmShareDownloads = false
    /// 已经接上的卷：可以写入的文件夹在外接硬盘上时，看它接上没有
    @State private var mountedVolumes = WritableFolders.mountedVolumes()

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
                Button("删除应用…", role: .destructive, action: onDelete)
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
        .confirmationDialog("还原到还原点？", isPresented: $confirmRestore) {
            Button("还原", role: .destructive) {
                perform {
                    try await box.restoreRestorePoint()
                    box.notice = String(localized: "已还原。")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("还原点之后的登录状态、设置和缓存都会丢弃。")
        }
        .confirmationDialog("删除还原点？", isPresented: $confirmDeleteRestorePoint) {
            Button("删除", role: .destructive) {
                perform {
                    try await box.deleteRestorePoint()
                    box.notice = String(localized: "还原点已删除。")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(box.config.resetOnQuit
                 ? String(localized: "删除后无法再回到这个状态，「每次退出后自动还原」也会关闭。")
                 : String(localized: "删除后无法再回到这个状态。"))
        }
        .confirmationDialog("允许「\(box.config.name)」写入「\(allowTargetName)」？",
                            isPresented: Binding(get: { allowTarget != nil }, set: { if !$0 { allowTarget = nil } }),
                            presenting: allowTarget) { folder in
            Button("允许写入") { box.allowWriting(to: folder) }
            Button("取消", role: .cancel) {}
        } message: { folder in
            Text(allowMessage(folder))
        }
        .confirmationDialog("共享「下载」文件夹给「\(box.config.name)」？",
                            isPresented: $confirmShareDownloads) {
            Button("共享") { box.config.shareDownloads = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用下载的文件直接保存到你的「下载」文件夹，删除应用后仍然保留；它也能修改、删除那里的文件。")
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            mountedVolumes = WritableFolders.mountedVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            mountedVolumes = WritableFolders.mountedVolumes()
        }
        .confirmationDialog("清除「\(box.config.name)」的数据？",
                            isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                perform {
                    try await box.clearData()
                    box.notice = String(localized: "数据已清除，下次打开就像刚安装一样。")
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(clearDataMessage)
        }
    }

    /// 清除数据不动还原点：还原点里同样有登录状态和钥匙串，之后还能还原回来，要说清楚
    private var clearDataMessage: String {
        var lines = [String(localized: "登录状态、设置、缓存和钥匙串都会被清空。应用本身保留。")]
        if box.restorePointDate != nil {
            lines.append(box.config.resetOnQuit
                         ? String(localized: "还原点不受影响。「每次退出后自动还原」开着，下次退出应用时数据会还原成还原点里的样子。")
                         : String(localized: "还原点不受影响，之后仍可还原到它。要连同还原点一起删除，请另外删除还原点。"))
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
                    TextField(String(localized: "名称"), text: $nameDraft)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .help("点击修改名称，按回车保存")
                        .onSubmit {
                            let name = nameDraft.trimmingCharacters(in: .whitespaces)
                            if name.isEmpty { nameDraft = box.config.name } else { box.config.name = name }
                        }
                        .onAppear { nameDraft = box.config.name }
                        .onChange(of: box.config.name) { nameDraft = box.config.name }
                    Text([box.config.version.map { String(localized: "版本 \($0)") }, box.config.bundleIdentifier]
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
                            Label("切换过去", systemImage: "arrow.up.forward").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        // 「退出」一直都在：应用问要不要存储、你点了取消接着用，之后照样可以再请求退出。
                        // 刚请求过的几秒里不能再点：重复请求会让应用再问一次
                        Button { box.quit() } label: {
                            Text(box.isQuitting ? String(localized: "正在退出…") : String(localized: "退出")).frame(maxWidth: .infinity)
                        }
                        .disabled(box.isQuitting)
                    } else {
                        Button { Task { await box.open() } } label: {
                            Label(box.config.isInstaller ? String(localized: "运行安装器") : String(localized: "打开"), systemImage: "play.fill")
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
                        Text("还没有退出？").foregroundStyle(.secondary)
                        Button("强制退出…") { forceQuitTarget = box }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .help("它可能在等你存储，也可能没有响应。强制退出会丢失没有存储的内容")
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

    /// 本机隔离时改用虚拟 Mac 的链接。自带苹果沙盒的一定运行不了（见 Box.cannotRunNatively），不问“不正常吗”
    static func virtualMacLinkTitle(_ box: Box) -> String {
        box.cannotRunNatively
            ? String(localized: "本机隔离运行不了它，改用虚拟 Mac 运行")
            : String(localized: "软件不正常？改用虚拟 Mac 运行")
    }

    private var runtimeSection: some View {
        Section {
            Picker("运行环境", selection: $box.config.runtime) {
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
                Button(Self.virtualMacLinkTitle(box)) { box.config.runtime = .virtualMac }
                    .buttonStyle(.link)
                    .disabled(box.isRunning || box.isBusy)
            } else {
                if !virtualMac.config.installed {
                    Label("虚拟 Mac 还没有设置。第一次需要下载约 18 GB 的 macOS 并安装，之后所有需要它的应用共用一台。",
                          systemImage: "info.circle")
                        .font(.caption)
                    Button("前往设置虚拟 Mac…") { store.show(.virtualMac) }
                } else {
                    Text("打开后，原始安装文件会放进虚拟 Mac 的「传入」文件夹（访达 › 位置 › My Shared Files），在里面安装一次即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("运行环境")
        }
    }

    // MARK: - 运行报告

    /// 这次（或上次）运行的概要，拦截记录可以展开，完整的报告在单独的窗口里
    private var reportSection: some View {
        Section {
            if let report = box.currentReport {
                Text(report.isRunning ? String(localized: "正在运行，边运行边记录。")
                                      : String(localized: "上次运行：\(RunReportLabel.time(report))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("写入文件") {
                    Text(report.fileTotals.map { String(localized: "\($0.count) 个 · \(FileOps.formatBytes($0.bytes))") }
                         ?? (report.isRunning ? String(localized: "退出后统计") : String(localized: "没能统计")))
                }
                LabeledContent("改动设置") {
                    Text(report.preferenceKeyCount.map { String(localized: "\($0) 项") }
                         ?? (report.isRunning ? String(localized: "退出后统计") : String(localized: "没能统计")))
                }
                if let strays = report.strayPreferences, !strays.isEmpty { strayRows(strays) }
                LabeledContent("连接服务器") {
                    Text(report.networkBlocked ? String(localized: "不联网") : String(localized: "\(report.servers.count) 个"))
                }
                LabeledContent("启动程序") {
                    Text("\(report.programs.count) 个")
                }
                if !report.blocks.isEmpty { blockRows(report) }
                Button("查看完整报告…") { showReport = true }
            } else {
                Text("打开应用后，这里会记下它写了哪些文件、改了哪些设置、连了哪些服务器、启动了哪些程序，以及哪些行为被拦下，可以导出分享。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("运行报告")
        }
    }

    /// 写在盒子外的设置：一行个数；还有能收进盒子的时候说一声去哪里收（收之前要看清是什么、再确认，所以只在完整报告里做）
    @ViewBuilder
    private func strayRows(_ strays: [StrayPreference]) -> some View {
        let pending = strays.filter { box.status(of: $0) == .adoptable }.count
        LabeledContent("写在盒子外") {
            Text("\(strays.count) 个设置文件")
                .foregroundStyle(pending > 0 ? .orange : .secondary)
        }
        if pending > 0 {
            Text("其中 \(pending) 个可能属于这个应用，删除盒子后会留在这台 Mac 上。可以在完整报告里收进盒子。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                      ? String(localized: "本次已拦截 \(total) 次越界行为") : String(localized: "拦截了 \(total) 次越界行为"),
                      systemImage: "hand.raised.fill")
                Spacer()
            }
            .contentShape(Rectangle())
            .foregroundStyle(report.blocks.contains(where: \.kind.suggestsVirtualMac) ? .orange : .secondary)
        }
        .buttonStyle(.plain)
        if !showAllBlocks {
            // 收起时也露出来：在应用里改了下载位置、被拒，回到 MacBox 就能看到，不用先展开
            ForEach(blockedFolders(report), id: \.self) { folder in
                HStack {
                    Text("写入「\((folder as NSString).lastPathComponent)」被挡住了")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("允许写入…") { allowTarget = folder }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if report.blocks.contains(where: blockedInDownloads) { shareDownloadsRow }
        }
        if showAllBlocks {
            ForEach(report.blocks) { block in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(block.kind.title)\(block.count > 1 ? " ×\(block.count)" : "")")
                        .font(.callout)
                    Text(block.targetText).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    if let folder = writableFolder(for: block) {
                        allowRow(folder, report: report)
                    } else if blockedInDownloads(block) {
                        shareDownloadsRow
                    }
                }
            }
        }
    }

    /// 不共享「下载」时直接写在「下载」里、被挡住了：建议共享「下载」（「下载」本身不能作为可以写入的文件夹，见 WritableFolders）
    private func blockedInDownloads(_ block: BlockEvent) -> Bool {
        !box.config.shareDownloads && block.kind == .personalFiles && WritableFolders.isDirectlyInDownloads(blockedWrite: block.target)
    }

    /// 运行中改不了（同详情面板里的开关）：只说明，退出后再给按钮
    private var shareDownloadsRow: some View {
        HStack {
            Text(box.isRunning || box.isBusy
                 ? String(localized: "写入「下载」被挡住了。退出应用后可以共享「下载」文件夹")
                 : String(localized: "写入「下载」被挡住了"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !box.isRunning, !box.isBusy {
                Button("共享「下载」…") { confirmShareDownloads = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// 被挡住的写入所在的文件夹：可以直接允许写入（在应用里选了下载位置、被拒，回到这里正好看到这条记录）
    private func writableFolder(for block: BlockEvent) -> String? {
        guard [.personalFiles, .other].contains(block.kind) else { return nil } // .other 里是写在主目录外的（外接硬盘……）
        return WritableFolders.folder(forBlockedWrite: block.target)
    }

    /// 被挡住的写入所在、还没允许写入的文件夹，去掉重复的
    private func blockedFolders(_ report: RunReport) -> [String] {
        var seen: Set<String> = []
        return report.blocks.compactMap(writableFolder(for:))
            .filter { !box.config.writableFolderPaths.contains($0) && seen.insert($0).inserted }
    }

    @ViewBuilder
    private func allowRow(_ folder: String, report: RunReport) -> some View {
        let name = (folder as NSString).lastPathComponent
        if box.config.writableFolderPaths.contains(folder) {
            // 这次运行开始之后才加的，要重新打开
            let pending = report.isRunning && report.writableFolders?.contains(WritableFolders.displayPath(folder)) != true
            Text(pending ? String(localized: "已允许写入「\(name)」，重新打开后生效")
                         : String(localized: "已允许写入「\(name)」"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("允许写入「\(name)」…") { allowTarget = folder }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var allowTargetName: String { allowTarget.map { ($0 as NSString).lastPathComponent } ?? "" }

    private func allowMessage(_ folder: String) -> String {
        let path = WritableFolders.displayPath(folder)
        var text = String(localized: "它可以新建、修改、删除「\(path)」里的文件，删除应用后这些文件仍然保留。")
        if box.isRunning {
            text += String(localized: "重新打开「\(box.config.name)」后生效。")
        }
        return text
    }

    // MARK: - 网络

    private var networkSection: some View {
        Section("网络") {
            Toggle("允许联网", isOn: $box.config.allowsNetwork)
                .disabled(box.isRunning || box.isBusy)
            Text(networkCaption)
                .font(.caption)
                .foregroundStyle(box.config.isInstaller && !box.config.allowsNetwork ? .orange : .secondary)
        }
    }

    private var networkCaption: String {
        if box.config.allowsNetwork {
            return String(localized: "关掉后，应用连不上任何服务器，在本机上的代理也连不上。下次打开时生效。")
        }
        if box.config.isInstaller {
            return String(localized: "在线安装器要联网才能下载安装包，不联网时它装不了。")
        }
        return String(localized: "应用连不上任何服务器，在本机上的代理也连不上；它显示的网页也打不开，用网页做的界面会是空白。登录、同步、更新都用不了。")
    }

    // MARK: - 安装器、聚焦

    /// 是不是在线安装器由文件名、大小猜出来，会猜错（下载器、卸载工具……）：让用户自己改。
    /// 只有本机隔离会接手安装；在虚拟 Mac 里运行时安装在虚拟 Mac 里完成，这个开关不起作用，不显示
    private var installerSection: some View {
        Section {
            if box.config.runtime == .isolated {
                Toggle("在线安装器", isOn: $box.config.isInstaller)
                    .disabled(box.isRunning || box.isBusy)
                Text(box.config.isInstaller
                     ? String(localized: "运行后会下载完整的安装包，MacBox 取出里面的 App 完成安装。如果这就是应用本身，请关掉。")
                     : String(localized: "如果这是一个运行后才下载完整安装包的小安装器，请打开，由 MacBox 接手安装。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let waitsForInstall = box.config.isInstaller && box.config.runtime == .isolated
            Toggle("在聚焦中显示", isOn: $box.config.showInLaunchpad)
                .disabled(waitsForInstall)
                .help("在 ~/Applications/MacBox 放一个启动器，像普通 App 一样打开")
            if waitsForInstall {
                Text("安装器没有启动器。安装完成后，启动器会按这里的设置创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 文件

    private var filesSection: some View {
        Section("文件") {
            Toggle("共享「下载」文件夹", isOn: $box.config.shareDownloads)
                .disabled(box.isRunning || box.isBusy)
            Text(box.config.shareDownloads
                 ? String(localized: "应用下载的文件直接保存到你的「下载」文件夹，删除应用后仍然保留；它也能修改、删除那里的文件。")
                 : String(localized: "应用只能看到盒子里自己的「下载」文件夹。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            writableFolderRows
            LabeledContent("应用数据") {
                if let dataSize { Text(FileOps.formatBytes(dataSize)) } else { ProgressView().controlSize(.small) }
            }
            HStack {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([box.paths.home]) }
                Spacer()
                Button("清除数据…") { confirmClear = true }
                    .disabled(box.isRunning || box.isBusy)
            }
        }
    }

    // MARK: - 可以写入的文件夹

    /// 应用可以写入的盒子外的文件夹（见 WritableFolders）。应用运行时也能改：正是要用的时候
    /// （在应用里把下载位置改到别处被拒，回到这里加上），重新打开应用后生效
    @ViewBuilder
    private var writableFolderRows: some View {
        let folders = box.config.writableFolderPaths
        LabeledContent("可以写入的文件夹") {
            Button("添加…", action: chooseWritableFolders)
        }
        ForEach(folders, id: \.self) { folder in
            WritableFolderRow(path: folder, connected: WritableFolders.volume(of: folder).map(mountedVolumes.contains) ?? true) {
                box.config.writableFolderPaths.removeAll { $0 == folder }
            }
        }
        Text(writableFoldersCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
        if let note = permissionNote(for: folders) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var writableFoldersCaption: String {
        var text = box.config.writableFolderPaths.isEmpty
            ? String(localized: "应用只能在盒子里写文件（共享时还有「下载」）。在应用里把下载位置改到别的文件夹之前，先把那个文件夹加到这里。")
            : String(localized: "应用可以新建、修改、删除这些文件夹里的文件；删除应用、清除数据、还原都不会动它们。")
        if box.isRunning {
            text += String(localized: "改动在重新打开「\(box.config.name)」后生效。")
        }
        return text
    }

    /// 在 macOS 保护的位置（外接硬盘、「文稿」……）里的：应用第一次写入时 macOS 会问，问的是盒子里的应用而不是 MacBox，要说清楚
    private func permissionNote(for folders: [String]) -> String? {
        let kinds = WritableFolders.Protected.allCases.filter { kind in folders.contains { WritableFolders.protection(of: $0) == kind } }
        guard !kinds.isEmpty else { return nil }
        let places = kinds.map(\.name).joined(separator: String(localized: "、"))
        let name = box.config.name
        let drive = kinds.contains(.drive)
        let driveNote = drive ? String(localized: "（外接硬盘问的是「可移除的宗卷」）") : ""
        return String(localized: "其中有\(places)里的文件夹：「\(name)」第一次写入时，macOS 可能会问是否允许它访问\(driveNote)。这是在问盒子里的这个应用，允许后它才能写入。macOS 会记住这个选择，删除应用后也还在，可以在「系统设置 › 隐私与安全性 › 文件与文件夹」里撤销。")
    }

    /// 用 MacBox 自己的选择框选：应用自己的选择框扩展不了沙盒规则。选中的解析成真实路径、检查过才加（见 WritableFolders）
    private func chooseWritableFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "允许写入")
        panel.message = String(localized: "选择「\(box.config.name)」可以写入的文件夹。最好选一个专门放它的文件的文件夹。")
        guard panel.runModal() == .OK else { return }
        var rejected: [String] = []
        for url in panel.urls {
            switch WritableFolders.resolve(url) {
            case .success(let folder): box.allowWriting(to: folder)
            case .failure(let rejection):
                rejected.append(String(localized: "「\(url.lastPathComponent)」：\(rejection.message)"))
            }
        }
        guard !rejected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = rejected.count == 1 ? String(localized: "这个文件夹不能允许写入")
                                                : String(localized: "有些文件夹不能允许写入")
        alert.informativeText = rejected.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - 还原点

    private var restoreSection: some View {
        Section("还原点") {
            if let date = box.restorePointDate {
                LabeledContent("创建于") {
                    HStack(spacing: 6) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                        // 放在这一行而不是下面的按钮行：英文的按钮名较长，三个按钮并排放不下
                        Button(role: .destructive) { confirmDeleteRestorePoint = true } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除还原点…")
                        .accessibilityLabel("删除还原点")
                        .disabled(box.isRunning || box.isBusy)
                    }
                }
            } else {
                Text("创建一个还原点，之后可以随时回到这个状态（比如刚登录好的时候）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(box.restorePointDate == nil ? String(localized: "创建还原点") : String(localized: "更新还原点")) {
                    perform {
                        try await box.createRestorePoint()
                        box.notice = String(localized: "还原点已创建。")
                    }
                }
                Button("还原…") { confirmRestore = true }
                    .disabled(box.restorePointDate == nil)
            }
            .disabled(box.isRunning || box.isBusy)
            Toggle("每次退出后自动还原", isOn: $box.config.resetOnQuit)
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

/// 可以写入的一个文件夹：名字、路径（主目录写成 ~），外接硬盘没接上时注明。MacBox 不去读它（见 WritableFolders）
private struct WritableFolderRow: View {
    let path: String
    let connected: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).font(.callout)
                    Text(WritableFolders.displayPath(path)).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            } icon: {
                Image(systemName: WritableFolders.volume(of: path) == nil ? "folder" : "externaldrive")
            }
            Spacer()
            if !connected {
                Text("硬盘没有接上").font(.caption).foregroundStyle(.orange)
            }
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("不再允许写入")
                .accessibilityLabel("不再允许写入「\((path as NSString).lastPathComponent)」")
        }
        // 由访达去打开，MacBox 自己不读这个文件夹
        .contextMenu {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
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
