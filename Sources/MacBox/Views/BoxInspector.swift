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
                Toggle("在启动台和聚焦中显示", isOn: $box.config.showInLaunchpad)
                    .help("在 ~/Applications/MacBox 放一个启动器，像普通 App 一样打开")
                Button("删除应用…", role: .destructive, action: onDelete)
                    .disabled(box.isRunning || box.isBusy)
            }
        }
        .formStyle(.grouped)
        // 统计占用空间要遍历整个主目录，放到后台，运行状态变化或数据变动后重新统计
        .task(id: "\(box.isRunning)-\(dataRevision)") {
            dataSize = await box.measureDataSize()
        }
        .confirmationDialog("还原到还原点？", isPresented: $confirmRestore) {
            Button("还原", role: .destructive) {
                perform {
                    try await box.restoreRestorePoint()
                    box.notice = "已还原。"
                    dataRevision += 1
                }
            }
        } message: {
            Text("还原点之后的登录状态、设置和缓存都会丢弃。")
        }
        .confirmationDialog("清除「\(box.config.name)」的数据？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                perform {
                    try await box.clearData()
                    box.notice = "数据已清除，下次打开就像刚安装一样。"
                    dataRevision += 1
                }
            }
        } message: {
            Text("登录状态、设置、缓存和钥匙串都会被清空。应用本身保留。")
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
                    TextField("名称", text: $nameDraft)
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
                    Text([box.config.version.map { "版本 \($0)" }, box.config.bundleIdentifier]
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
                            Label("切换过去", systemImage: "arrow.up.forward").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { box.quit() } label: { Text("退出").frame(maxWidth: .infinity) }
                    } else {
                        Button { Task { await box.open() } } label: {
                            Label(box.config.isInstaller ? "运行安装器" : "打开", systemImage: "play.fill")
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
                if !box.blocks.isEmpty {
                    // Form 里的 DisclosureGroup 在 macOS 上点不开，自己做展开行
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showAllBlocks.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showAllBlocks ? 90 : 0))
                                .font(.caption.weight(.semibold))
                            Label("本次已拦截 \(box.blocks.reduce(0) { $0 + $1.count }) 次越界行为", systemImage: "hand.raised.fill")
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
                Button("软件不正常？改用虚拟 Mac 运行") { box.config.runtime = .virtualMac }
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

    // MARK: - 文件

    private var filesSection: some View {
        Section("文件") {
            Toggle("共享「下载」文件夹", isOn: $box.config.shareDownloads)
                .disabled(box.isRunning || box.isBusy)
            Text(box.config.shareDownloads
                 ? "应用下载的文件直接保存到你的「下载」文件夹。"
                 : "应用只能看到盒子里自己的「下载」文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    // MARK: - 还原点

    private var restoreSection: some View {
        Section("还原点") {
            if let date = box.restorePointDate {
                LabeledContent("创建于", value: date.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("创建一个还原点，之后可以随时回到这个状态（比如刚登录好的时候）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(box.restorePointDate == nil ? "创建还原点" : "更新还原点") {
                    perform {
                        try await box.createRestorePoint()
                        box.notice = "还原点已创建。"
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

private struct IssueRow: View {
    let issue: CompatibilityIssue

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.callout)
                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
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
