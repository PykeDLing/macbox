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
                Text("本机隔离容纳不了的应用（需要驱动、系统服务等）在虚拟 Mac 中运行。所有这类应用共用一台，只在需要时设置。")
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
                    Button("删除虚拟 Mac…", role: .destructive) { confirmRemove = true }
                        .disabled(vm.isActive)
                }
            }
        }
        .formStyle(.grouped)
        .pageWidth()
        .navigationTitle("虚拟 Mac")
        .navigationSubtitle(vm.displayStatus)
        .onAppear { vm.refreshFlags() }
        .confirmationDialog("删除 macOS 安装镜像缓存？", isPresented: $confirmDeleteCache) {
            Button("删除", role: .destructive) { perform { try vm.deleteInstallerCache() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("镜像只在设置虚拟 Mac 时使用一次，删除后可以随时重新下载。")
        }
        .confirmationDialog("删除虚拟 Mac？", isPresented: $confirmRemove) {
            Button("移到废纸篓", role: .destructive) { perform { try vm.remove() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("虚拟 Mac 里安装的应用和文件会一起移到废纸篓。")
        }
        .confirmationDialog("删除虚拟 Mac 的还原点？", isPresented: $confirmDeleteRestorePoint) {
            Button("删除", role: .destructive) { perform { try vm.deleteRestorePoint() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法再回到这个状态。")
        }
        .confirmationDialog("把虚拟 Mac 还原到还原点？", isPresented: $confirmRestore) {
            Button("还原", role: .destructive) { perform { try vm.restoreRestorePoint() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("还原点之后在虚拟 Mac 里的改动都会丢弃（「传入」「传出」文件夹不受影响）。")
        }
        .confirmationDialog("更新还原点？", isPresented: $confirmUpdateRestorePoint) {
            Button("更新", role: .destructive) { perform { try vm.createRestorePoint() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(restorePointDateText) 的还原点会被虚拟 Mac 现在的状态替换，之后无法再回到原来那个状态。")
        }
        .confirmationDialog("丢弃睡眠状态？", isPresented: $confirmDiscardSleep) {
            Button("丢弃", role: .destructive) { perform { try vm.discardSleepState() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("虚拟 Mac 下次会正常开机，睡眠时打开的应用和没有保存的内容都会丢失。")
        }
        .confirmationDialog("把虚拟 Mac 移到废纸篓？", isPresented: $confirmTrashUnreadable) {
            Button("移到废纸篓", role: .destructive) { perform { try vm.trashUnreadable() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("整个虚拟 Mac 文件夹会移到废纸篓，之后可以重新设置。需要的话仍然可以从废纸篓找回。")
        }
    }

    private var restorePointDateText: String {
        vm.restorePointDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    @ViewBuilder
    private var setupSection: some View {
        @Bindable var vm = vm
        Section("设置虚拟 Mac") {
            Text("需要从 Apple 下载约 18 GB 的 macOS 并安装，完成后占用约 30 GB（安装镜像可在完成后删除）。整个过程约 20–40 分钟。")
                .font(.callout)
            InstallSourcePicker(source: $source)
            ResourceSteppers(cpuCount: $vm.config.cpuCount, memoryGB: $vm.config.memoryGB)
            Button("开始设置") { vm.beginSetup(from: source) }
                .buttonStyle(.borderedProminent)
        }
    }

    /// 配置读不出来：不覆盖它，也不允许重新设置（重新设置会重建虚拟硬盘）。
    /// 只剩虚拟硬盘、没有 config.json 时（多半是没完成的设置）给出移到废纸篓的出路；
    /// config.json 还在却读不出来时不提供，那可能是更新版本的 MacBox 写的
    private func unreadableSection(_ message: String) -> some View {
        Section("配置无法读取") {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            if vm.canTrashUnreadable {
                Text("这多半是之前的设置没有完成（中途取消、失败，或者设置时退出了 MacBox）。可以把虚拟 Mac 移到废纸篓，然后重新设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url]) }
                    Button("移到废纸篓…", role: .destructive) { confirmTrashUnreadable = true }
                }
            } else {
                Text("为避免丢失虚拟硬盘里的数据，MacBox 不会覆盖或重建它。请检查或修复下面这个文件后重新打开 MacBox。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("在访达中显示配置文件") { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.configURL]) }
            }
        }
    }

    private var installingSection: some View {
        Section("正在设置") {
            Text(vm.installPhase)
            if let progress = vm.installProgress {
                ProgressView(value: progress) {
                    Text(progress.formatted(.percent.precision(.fractionLength(1)))).font(.caption).monospacedDigit()
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Button("取消", role: .cancel) { vm.cancelSetup() }
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
                Text("虚拟 Mac").font(.title3.weight(.semibold))
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
                Label(vm.isAsleep ? String(localized: "唤醒") : String(localized: "启动"), systemImage: "play.fill").frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        default:
            HStack(spacing: 8) {
                Button("睡眠") { Task { await vm.sleep() } }
                    .disabled(vm.status != .running && vm.status != .paused)
                // 只有运行中才能正常关机（暂停、启动、睡眠途中点了也不会有反应）
                Button("关机") { vm.requestShutdown() }
                    .disabled(vm.status != .running)
                Button("显示窗口") { openWindow(id: WindowID.virtualMac.rawValue) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
    }

    private var exchangeSection: some View {
        Section {
            LabeledContent("传入") {
                HStack {
                    if vm.isSending { ProgressView().controlSize(.small) }
                    Button("放入文件…") { choosingGuestFiles = true }
                        .fileImporter(isPresented: $choosingGuestFiles, allowedContentTypes: [.item, .folder],
                                      allowsMultipleSelection: true) { result in
                            if case .success(let urls) = result { Task { await vm.sendToGuest(urls) } }
                        }
                }
            }
            LabeledContent("传出") {
                Button("打开「传出」文件夹") { Task { await vm.openOutgoingFolder() } }
            }
        } header: {
            Text("文件交换")
        } footer: {
            // 放行不会在「传出」里保留：系统放行只是改隔离标记的标志位，和客体伪造分不出来，见 OutgoingQuarantine.isValidMark
            Text("在虚拟 Mac 里，这两个文件夹位于 访达 › 位置 › My Shared Files。「传出」里的文件来自虚拟 Mac，会像下载的文件一样加上隔离标记，打开时由 macOS 检查。在「传出」里放行过的应用之后还会再被检查，要长期使用请先把它移出来。")
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        @Bindable var vm = vm
        Section("资源") {
            Group {
                ResourceSteppers(cpuCount: $vm.config.cpuCount, memoryGB: $vm.config.memoryGB)
                Toggle("允许联网", isOn: $vm.config.networkEnabled)
                Toggle("声音输出", isOn: $vm.config.audioEnabled)
            }
            .disabled(!vm.canChangeResources)
            if vm.status == .stopped && vm.isAsleep {
                // 睡眠状态只能按保存时的硬件唤醒：改了资源，唤醒就会失败
                Text("睡眠中的虚拟 Mac 只能按原来的资源唤醒。要修改资源，请先唤醒再关机，或者丢弃睡眠状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("丢弃睡眠状态…", role: .destructive) { confirmDiscardSleep = true }
            } else if !vm.canChangeResources {
                Text("修改资源需要先关闭虚拟 Mac。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var restoreSection: some View {
        Section("还原点") {
            if let date = vm.restorePointDate {
                LabeledContent("创建于", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            HStack {
                Button(vm.restorePointDate == nil ? String(localized: "创建还原点") : String(localized: "更新还原点…")) {
                    // 已有还原点时会被替换，先确认
                    if vm.restorePointDate == nil { perform { try vm.createRestorePoint() } } else { confirmUpdateRestorePoint = true }
                }
                Button("还原…") { confirmRestore = true }.disabled(vm.restorePointDate == nil)
                if vm.restorePointDate != nil {
                    Spacer()
                    Button("删除…") { confirmDeleteRestorePoint = true }
                }
            }
            .disabled(vm.status != .stopped)
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        let apps = store.boxes.filter { $0.config.runtime == .virtualMac }
        if !apps.isEmpty {
            Section("在虚拟 Mac 中运行的应用") {
                ForEach(apps) { box in
                    HStack {
                        Image(nsImage: box.icon).resizable().frame(width: 20, height: 20)
                        Text(box.config.name)
                        Spacer()
                        Button("改回本机隔离") { box.config.runtime = .isolated }
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
                    Button("删除安装镜像缓存…") { confirmDeleteCache = true }
                        .disabled(vm.status == .installing)
                }
            } header: {
                Text("占用空间")
            } footer: {
                Text("虚拟硬盘是稀疏文件，只占用实际写入的空间；但虚拟 Mac 里删除的文件不一定会把空间还给本机。")
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
            LabeledContent("CPU 核心",
                           value: String(localized: "\(cpuCount) 核"))
        }
        Stepper(value: $memoryGB, in: 4...max(4, hostMemory - 4), step: 2) {
            LabeledContent("内存", value: "\(memoryGB) GB")
        }
    }
}

struct InstallSourcePicker: View {
    @Binding var source: InstallSource
    @State private var extraFiles: [URL] = []
    @State private var choosingFile = false

    var body: some View {
        Picker("macOS 镜像", selection: $source) {
            Text("自动下载适用于本机的最新版本").tag(InstallSource.latest)
            ForEach(Self.options(cached: RestoreImageStore.cachedImages(), extra: extraFiles, selected: source), id: \.self) { url in
                Text(url.lastPathComponent).tag(InstallSource.file(url))
            }
        }
        .pickerStyle(.radioGroup)
        Button("选择本地 IPSW 文件…") { choosingFile = true }
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
