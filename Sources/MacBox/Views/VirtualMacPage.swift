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
    @State private var confirmUpdateRestorePoint = false
    @State private var confirmDiscardSleep = false
    @State private var confirmTrashUnreadable = false

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

            if vm.canRemove {
                Section {
                    Button(L("删除虚拟 Mac…", "Delete Virtual Mac…"), role: .destructive) { confirmRemove = true }
                        .disabled(vm.isActive)
                }
            }
        }
        .formStyle(.grouped)
        .pageWidth()
        .navigationTitle(L("虚拟 Mac", "Virtual Mac"))
        .navigationSubtitle(vm.displayStatus)
        .onAppear { vm.refreshFlags() }
        .confirmationDialog(L("删除 macOS 安装镜像缓存？", "Delete the Cached macOS Restore Image?"), isPresented: $confirmDeleteCache) {
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
        .confirmationDialog(L("更新还原点？", "Update the Restore Point?"), isPresented: $confirmUpdateRestorePoint) {
            Button(L("更新", "Update"), role: .destructive) { perform { try vm.createRestorePoint() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("\(restorePointDateText) 的还原点会被虚拟 Mac 现在的状态替换，之后无法再回到原来那个状态。",
                   "The restore point from \(restorePointDateText) will be replaced with the Virtual Mac’s current state. You won’t be able to return to the earlier state."))
        }
        .confirmationDialog(L("丢弃睡眠状态？", "Discard the Sleep State?"), isPresented: $confirmDiscardSleep) {
            Button(L("丢弃", "Discard"), role: .destructive) { perform { try vm.discardSleepState() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("虚拟 Mac 下次会正常开机，睡眠时打开的应用和没有保存的内容都会丢失。",
                   "The Virtual Mac will start up normally next time. Apps that were open and any unsaved work will be lost."))
        }
        .confirmationDialog(L("把虚拟 Mac 移到废纸篓？", "Move the Virtual Mac to the Trash?"), isPresented: $confirmTrashUnreadable) {
            Button(L("移到废纸篓", "Move to Trash"), role: .destructive) { perform { try vm.trashUnreadable() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("整个虚拟 Mac 文件夹会移到废纸篓，之后可以重新设置。需要的话仍然可以从废纸篓找回。",
                   "The whole Virtual Mac folder will be moved to the Trash, and you can set it up again. You can still recover it from the Trash if you need to."))
        }
    }

    private var restorePointDateText: String {
        vm.restorePointDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
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

    /// 配置读不出来：不覆盖它，也不允许重新设置（重新设置会重建虚拟硬盘）。
    /// 只剩虚拟硬盘、没有 config.json 时（多半是没完成的设置）给出移到废纸篓的出路；
    /// config.json 还在却读不出来时不提供，那可能是更新版本的 MacBox 写的
    private func unreadableSection(_ message: String) -> some View {
        Section(L("配置无法读取", "Can’t Read Configuration")) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            if vm.canTrashUnreadable {
                Text(L("这多半是之前的设置没有完成（中途取消、失败，或者设置时退出了 MacBox）。可以把虚拟 Mac 移到废纸篓，然后重新设置。",
                       "This usually means an earlier setup didn’t finish (it was canceled or failed, or MacBox quit during setup). You can move the Virtual Mac to the Trash and set it up again."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(L("在访达中显示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url]) }
                    Button(L("移到废纸篓…", "Move to Trash…"), role: .destructive) { confirmTrashUnreadable = true }
                }
            } else {
                Text(L("为避免丢失虚拟硬盘里的数据，MacBox 不会覆盖或重建它。请检查或修复下面这个文件后重新打开 MacBox。",
                       "To avoid losing data on the virtual disk, MacBox won’t overwrite or recreate it. Check or repair the file below, then reopen MacBox."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("在访达中显示配置文件", "Show Configuration File in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.configURL]) }
            }
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
                    Label(vm.displayStatus, systemImage: "circle.fill")
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
                // 只有运行中才能正常关机（暂停、启动、睡眠途中点了也不会有反应）
                Button(L("关机", "Shut Down")) { vm.requestShutdown() }
                    .disabled(vm.status != .running)
                Button(L("显示窗口", "Show Window")) { openWindow(id: WindowID.virtualMac.rawValue) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }

    private var exchangeSection: some View {
        Section {
            LabeledContent(L("传入", "“传入” (Incoming)")) {
                HStack {
                    if vm.isSending { ProgressView().controlSize(.small) }
                    Button(L("放入文件…", "Add Files…")) { choosingGuestFiles = true }
                        .fileImporter(isPresented: $choosingGuestFiles, allowedContentTypes: [.item, .folder],
                                      allowsMultipleSelection: true) { result in
                            if case .success(let urls) = result { Task { await vm.sendToGuest(urls) } }
                        }
                }
            }
            LabeledContent(L("传出", "“传出” (Outgoing)")) {
                Button(L("打开「传出」文件夹", "Open “传出” Folder")) { Task { await vm.openOutgoingFolder() } }
            }
        } header: {
            Text(L("文件交换", "File Exchange"))
        } footer: {
            Text(L("在虚拟 Mac 里，这两个文件夹位于 访达 › 位置 › My Shared Files。「传出」里的文件来自虚拟 Mac，会像下载的文件一样加上隔离标记，第一次打开时由 macOS 检查。",
                   "In the Virtual Mac, these folders appear as “传入” and “传出” under Finder › Locations › My Shared Files. Files in “传出” come from the Virtual Mac, so they’re quarantined like downloads and checked by macOS the first time they’re opened."))
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        @Bindable var vm = vm
        Section(L("资源", "Resources")) {
            Group {
                ResourceSteppers(cpuCount: $vm.config.cpuCount, memoryGB: $vm.config.memoryGB)
                Toggle(L("允许联网", "Allow Network Access"), isOn: $vm.config.networkEnabled)
                Toggle(L("声音输出", "Sound Output"), isOn: $vm.config.audioEnabled)
            }
            .disabled(!vm.canChangeResources)
            if vm.status == .stopped && vm.isAsleep {
                // 睡眠状态只能按保存时的硬件唤醒：改了资源，唤醒就会失败
                Text(L("睡眠中的虚拟 Mac 只能按原来的资源唤醒。要修改资源，请先唤醒再关机，或者丢弃睡眠状态。",
                       "A Virtual Mac that’s asleep can only wake with the resources it had when it went to sleep. To change resources, wake it and shut it down, or discard its sleep state."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("丢弃睡眠状态…", "Discard Sleep State…"), role: .destructive) { confirmDiscardSleep = true }
            } else if !vm.canChangeResources {
                Text(L("修改资源需要先关闭虚拟 Mac。", "Shut down the Virtual Mac to change resources.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var restoreSection: some View {
        Section(L("还原点", "Restore Point")) {
            if let date = vm.restorePointDate {
                LabeledContent(L("创建于", "Created"), value: date.formatted(date: .abbreviated, time: .shortened))
            }
            HStack {
                Button(vm.restorePointDate == nil ? L("创建还原点", "Create Restore Point") : L("更新还原点…", "Update Restore Point…")) {
                    // 已有还原点时会被替换，先确认
                    if vm.restorePointDate == nil { perform { try vm.createRestorePoint() } } else { confirmUpdateRestorePoint = true }
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
            ForEach(Self.options(cached: RestoreImageStore.cachedImages(), extra: extraFiles, selected: source), id: \.self) { url in
                Text(url.lastPathComponent).tag(InstallSource.file(url))
            }
        }
        .pickerStyle(.radioGroup)
        Button(L("选择本地 IPSW 文件…", "Choose Local IPSW File…")) { choosingFile = true }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data]) { result in
                guard case .success(let picked) = result else { return }
                let url = Self.normalized(picked)
                if !extraFiles.contains(url) { extraFiles.append(url) }
                source = .file(url)
            }
    }

    /// 同一个文件只算一次：按解析符号链接后的路径比较。ForEach 的 id 重复时行会重复或丢失，选中项也对不上
    static func normalized(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    /// 单选列表里的镜像文件：缓存的、这次选过的，再加上当前选中的那个。
    /// 设置失败回到这一页时，页面还记着选中的文件，这里的 extraFiles 却已经随视图重建清空了，不补上就看不到选中了什么
    static func options(cached: [URL], extra: [URL], selected: InstallSource) -> [URL] {
        var candidates = cached + extra
        if case .file(let url) = selected { candidates.append(url) }
        var seen = Set<String>()
        return candidates.map(normalized).filter { seen.insert($0.path).inserted }
    }
}
