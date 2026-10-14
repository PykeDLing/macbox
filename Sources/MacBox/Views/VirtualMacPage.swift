import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口里的「虚拟 Mac」页
struct VirtualMacPage: View {
    @Environment(VirtualMac.self) private var vm
    @Environment(BoxStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var choosingGuestFiles = false
    @State private var source: InstallSource = .latest
    @State private var confirmDeleteCache = false
    @State private var confirmRemove = false
    @State private var confirmRestore = false
    @State private var confirmDeleteRestorePoint = false

    var body: some View {
        Form {
            Section {
                hero
                if let error = vm.lastError {
                    Banner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red) { vm.lastError = nil }
                }
                if let notice = vm.notice {
                    Banner(text: notice, systemImage: "info.circle.fill", tint: .blue) { vm.notice = nil }
                }
            } footer: {
                Text(L("本机隔离容纳不了的应用（需要驱动、系统服务等）在虚拟 Mac 中运行。所有这类应用共用一台，只在需要时设置。",
                       "Apps that Native Isolation can’t contain (ones that need drivers, system services and so on) run in a Virtual Mac. All such apps share a single one, which is set up only when needed."))
            }

            switch vm.status {
            case .notSetUp: setupSection
            case .installing: installingSection
            case .unreadable(let message): unreadableSection(message)
            default:
                exchangeSection
                resourcesSection
                restoreSection
            }

            appsSection
            storageSection

            if vm.config.installed {
                Section {
                    Button(L("删除虚拟 Mac…", "Delete Virtual Mac…"), role: .destructive) { confirmRemove = true }
                        .disabled(vm.isActive)
                }
            }
        }
        .formStyle(.grouped)
        .pageWidth()
        .navigationTitle(L("虚拟 Mac", "Virtual Mac"))
        .navigationSubtitle(vm.status.title)
        .onAppear { vm.refreshFlags() }
        .confirmationDialog(L("删除 macOS 安装镜像缓存？", "Delete the cached macOS restore image?"), isPresented: $confirmDeleteCache) {
            Button(L("删除", "Delete"), role: .destructive) { perform { try vm.deleteInstallerCache() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("镜像只在设置虚拟 Mac 时使用一次，删除后可以随时重新下载。",
                   "The image is only used once, when setting up the Virtual Mac. You can download it again at any time."))
        }
        .confirmationDialog(L("删除虚拟 Mac？", "Delete the Virtual Mac?"), isPresented: $confirmRemove) {
            Button(L("移到废纸篓", "Move to Trash"), role: .destructive) { perform { try vm.remove() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("虚拟 Mac 里安装的应用和文件会一起移到废纸篓。",
                   "Apps and files installed in the Virtual Mac will be moved to the Trash along with it."))
        }
        .confirmationDialog(L("删除虚拟 Mac 的还原点？", "Delete the Virtual Mac’s Restore Point?"), isPresented: $confirmDeleteRestorePoint) {
            Button(L("删除", "Delete"), role: .destructive) { perform { try vm.deleteRestorePoint() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("删除后无法再回到这个状态。", "You won’t be able to return to this state."))
        }
        .confirmationDialog(L("还原到还原点？", "Restore the Virtual Mac to the Restore Point?"), isPresented: $confirmRestore) {
            Button(L("还原", "Restore"), role: .destructive) { perform { try vm.restoreRestorePoint() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("还原点之后在虚拟 Mac 里的改动都会丢弃（「传入」「传出」文件夹不受影响）。",
                   "All changes made in the Virtual Mac since the restore point will be discarded. (The shared “传入” (Incoming) and “传出” (Outgoing) folders aren’t affected.)"))
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        @Bindable var vm = vm
        Section(L("设置虚拟 Mac", "Set Up Virtual Mac")) {
            Text(L("需要从 Apple 下载约 18 GB 的 macOS 并安装，完成后占用约 30 GB（安装镜像可在完成后删除）。整个过程约 20–40 分钟。",
                   "About 18 GB of macOS will be downloaded from Apple and installed, using about 30 GB when finished (the restore image can be deleted afterward). The whole process takes about 20–40 minutes."))
                .font(.callout)
            InstallSourcePicker(source: $source)
            ResourceSteppers(cpuCount: $vm.config.cpuCount, memoryGB: $vm.config.memoryGB)
            Button(L("开始设置", "Start Setup")) { vm.beginSetup(from: source) }
                .buttonStyle(.borderedProminent)
        }
    }

    /// 配置文件存在但读不出来：不覆盖它，也不允许重新设置（重新设置会重建虚拟硬盘）
    private func unreadableSection(_ message: String) -> some View {
        Section(L("配置无法读取", "Can’t Read Configuration")) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            Text(L("为避免丢失虚拟硬盘里的数据，MacBox 不会覆盖或重建它。请检查或修复下面这个文件后重新打开 MacBox。",
                   "To avoid losing data on the virtual disk, MacBox won’t overwrite or recreate it. Check or repair the file below, then reopen MacBox."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L("在访达中显示配置文件", "Show Configuration File in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.configURL]) }
        }
    }

    private var installingSection: some View {
        Section(L("正在设置", "Setting Up")) {
            Text(vm.installPhase)
            if let progress = vm.installProgress {
                ProgressView(value: progress) {
                    Text(progress.formatted(.percent.precision(.fractionLength(1)))).font(.caption).monospacedDigit()
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Button(L("取消", "Cancel"), role: .cancel) { vm.cancelSetup() }
        }
    }

    private var statusTitle: String { vm.isAsleep && vm.status == .stopped ? L("睡眠中", "Asleep") : vm.status.title }

    private var hero: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(LinearGradient(colors: [Color(red: 0.45, green: 0.5, blue: 0.62), Color(red: 0.28, green: 0.32, blue: 0.42)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("虚拟 Mac", "Virtual Mac")).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Label(statusTitle, systemImage: "circle.fill")
                        .labelStyle(StatusLabelStyle(color: vm.status == .running ? .green : .secondary))
                    if let os = vm.config.osVersion { Text(os).foregroundStyle(.secondary) }
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            heroActions
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var heroActions: some View {
        switch vm.status {
        case .notSetUp, .installing, .unreadable:
            EmptyView()
        case .stopped:
            Button {
                openWindow(id: WindowID.virtualMac.rawValue)
                Task { await vm.start() }
            } label: {
                Label(vm.isAsleep ? L("唤醒", "Wake") : L("启动", "Start"), systemImage: "play.fill").frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        default:
            HStack(spacing: 8) {
                Button(L("睡眠", "Sleep")) { Task { await vm.sleep() } }
                    .disabled(vm.status != .running && vm.status != .paused)
                Button(L("关机", "Shut Down")) { vm.requestShutdown() }
                Button(L("显示窗口", "Show Window")) { openWindow(id: WindowID.virtualMac.rawValue) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }

    private var exchangeSection: some View {
        Section {
            LabeledContent(L("传入", "“传入” (Incoming)")) {
                Button(L("放入文件…", "Add Files…")) { choosingGuestFiles = true }
                    .fileImporter(isPresented: $choosingGuestFiles, allowedContentTypes: [.item, .folder],
                                  allowsMultipleSelection: true) { result in
                        if case .success(let urls) = result { vm.sendToGuest(urls) }
                    }
            }
            LabeledContent(L("传出", "“传出” (Outgoing)")) {
                Button(L("打开「传出」文件夹", "Open “传出” Folder")) {
                    try? vm.bundle.ensureExchangeFolders()
                    NSWorkspace.shared.open(vm.bundle.outgoingURL)
                }
            }
        } header: {
            Text(L("文件交换", "File Exchange"))
        } footer: {
            Text(L("在虚拟 Mac 里，这两个文件夹位于 访达 › 位置 › My Shared Files。",
                   "In the Virtual Mac, these folders appear as “传入” and “传出” under Finder › Locations › My Shared Files."))
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        @Bindable var vm = vm
        Section(L("资源", "Resources")) {
            ResourceSteppers(cpuCount: $vm.config.cpuCount, memoryGB: $vm.config.memoryGB)
            Toggle(L("允许联网", "Allow Network Access"), isOn: $vm.config.networkEnabled)
            Toggle(L("声音输出", "Sound Output"), isOn: $vm.config.audioEnabled)
            if vm.status != .stopped {
                Text(L("修改资源需要先关闭虚拟 Mac。", "Shut down the Virtual Mac to change resources.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(vm.status != .stopped)
    }

    private var restoreSection: some View {
        Section(L("还原点", "Restore Point")) {
            if let date = vm.restorePointDate {
                LabeledContent(L("创建于", "Created"), value: date.formatted(date: .abbreviated, time: .shortened))
            }
            HStack {
                Button(vm.restorePointDate == nil ? L("创建还原点", "Create Restore Point") : L("更新还原点", "Update Restore Point")) {
                    perform { try vm.createRestorePoint() }
                }
                Button(L("还原…", "Restore…")) { confirmRestore = true }.disabled(vm.restorePointDate == nil)
                if vm.restorePointDate != nil {
                    Spacer()
                    Button(L("删除…", "Delete…")) { confirmDeleteRestorePoint = true }
                }
            }
            .disabled(vm.status != .stopped)
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        let apps = store.boxes.filter { $0.config.runtime == .virtualMac }
        if !apps.isEmpty {
            Section(L("在虚拟 Mac 中运行的应用", "Apps That Use the Virtual Mac")) {
                ForEach(apps) { box in
                    HStack {
                        Image(nsImage: box.icon).resizable().frame(width: 20, height: 20)
                        Text(box.config.name)
                        Spacer()
                        Button(L("改回本机隔离", "Switch Back to Native Isolation")) { box.config.runtime = .isolated }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        let items = vm.storageBreakdown()
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    LabeledContent(item.title, value: FileOps.formatBytes(item.bytes))
                }
                if items.contains(where: { $0.id == "ipsw" }) {
                    Button(L("删除安装镜像缓存…", "Delete Cached Restore Image…")) { confirmDeleteCache = true }
                        .disabled(vm.status == .installing)
                }
            } header: {
                Text(L("占用空间", "Storage"))
            } footer: {
                Text(L("虚拟硬盘是稀疏文件，只占用实际写入的空间；但虚拟 Mac 里删除的文件不一定会把空间还给本机。",
                       "The virtual disk is a sparse file that only uses space for data actually written. However, deleting files in the Virtual Mac doesn’t always return the space to this Mac."))
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { vm.lastError = error.localizedDescription }
    }
}

struct ResourceSteppers: View {
    @Binding var cpuCount: Int
    @Binding var memoryGB: Int
    private let hostCPU = ProcessInfo.processInfo.processorCount
    private let hostMemory = Int(ProcessInfo.processInfo.physicalMemory >> 30)

    var body: some View {
        Stepper(value: $cpuCount, in: 2...max(2, hostCPU)) {
            LabeledContent(L("CPU 核心", "CPU Cores"),
                           value: L("\(cpuCount) 核", cpuCount == 1 ? "1 core" : "\(cpuCount) cores"))
        }
        Stepper(value: $memoryGB, in: 4...max(4, hostMemory - 4), step: 2) {
            LabeledContent(L("内存", "Memory"), value: "\(memoryGB) GB")
        }
    }
}

struct InstallSourcePicker: View {
    @Binding var source: InstallSource
    @State private var extraFiles: [URL] = []
    @State private var choosingFile = false

    var body: some View {
        Picker(L("macOS 镜像", "macOS Image"), selection: $source) {
            Text(L("自动下载适用于本机的最新版本", "Automatically download the latest version for this Mac")).tag(InstallSource.latest)
            ForEach(RestoreImageStore.cachedImages() + extraFiles, id: \.self) { url in
                Text(url.lastPathComponent).tag(InstallSource.file(url))
            }
        }
        .pickerStyle(.radioGroup)
        Button(L("选择本地 IPSW 文件…", "Choose Local IPSW File…")) { choosingFile = true }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data]) { result in
                guard case .success(let url) = result else { return }
                extraFiles.append(url)
                source = .file(url)
            }
    }
}
