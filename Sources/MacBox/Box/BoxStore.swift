import AppKit
import Foundation
import Observation

/// 兼容性问题出现时的处理方式（设置 › 通用）
enum CompatibilityPolicy: String, CaseIterable, Identifiable {
    case ask, switchAutomatically
    var id: String { rawValue }
    var title: String { self == .ask ? L("询问我", "Ask Me") : L("自动改用虚拟 Mac", "Switch to Virtual Mac Automatically") }
    static let key = "compatibilityPolicy"
    static var current: CompatibilityPolicy {
        CompatibilityPolicy(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ask
    }
}

/// 主窗口侧边栏的页面
enum Destination: Hashable {
    case allApps, running, virtualMac, settings
}

struct CompatibilityPrompt: Identifiable {
    let id = UUID()
    let boxID: UUID
    let appName: String
    let reasons: [String]
}

/// App 的窗口
enum WindowID: String {
    case library
    case virtualMac = "virtual-mac"
}

/// 请求界面打开某个窗口（每次请求都是新值，重复请求同一窗口也会触发）
struct WindowRequest: Equatable {
    let window: WindowID
    let id = UUID()
}

/// box.json 读不出来的盒子：照原样保留，不覆盖、不删除它的启动器，由用户决定怎么处理
struct BrokenBox: Identifiable {
    let id: UUID
    let url: URL
    let message: String
}

@Observable
final class BoxStore {
    static let shared = BoxStore()

    private(set) var boxes: [Box] = []
    private(set) var brokenBoxes: [BrokenBox] = []
    var selection: UUID?
    private(set) var importStatus: String?
    var importError: String?
    var prompt: CompatibilityPrompt?
    var destination: Destination = .allApps
    /// 由 App 场景消费：打开对应窗口
    var windowRequest: WindowRequest?

    /// MacBox 正在退出
    @ObservationIgnored private(set) var isTerminating = false
    @ObservationIgnored private var started = false
    /// 上次异常退出的收尾；启动应用、导入之前都要等它完成
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var volumeWatchers: [Task<Void, Never>] = []
    @ObservationIgnored private var lastRelaunch: [UUID: Date] = [:]

    /// 不做任何事；读取盒子、启动守卫等都在 start() 里
    init() {}

    /// 读取盒子、收尾上次异常退出、启动守卫。可重复调用，只有第一次生效
    func start() {
        guard !started else { return }
        started = true
        reload()
        recovery = Task { await recoverInterruptedSessions() }
        EscapeGuard.shared.start { [weak self] escape in self?.handleEscape(escape) }
        // 有卷挂载/卸载时立即更新守卫（安装器挂载 dmg 后常常马上从卷上启动 App）
        let center = NSWorkspace.shared.notificationCenter
        volumeWatchers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            Task.detached {
                for await _ in center.notifications(named: name) { await EscapeGuard.refreshVolumes() }
            }
        }
        Task { await EscapeGuard.refreshVolumes() }
    }

    /// 等待启动时的收尾完成
    func ready() async {
        start()
        await recovery?.value
    }

    private func reload() {
        _ = try? AppPaths.ensure(AppPaths.boxes)
        var loaded: [Box] = []
        var broken: [BrokenBox] = []
        for url in FileOps.contents(of: AppPaths.boxes) where url.pathExtension == "box" {
            let paths = BoxPaths(url: url)
            do {
                let box = Box(paths: paths, config: try paths.loadConfig())
                box.store = self
                loaded.append(box)
            } catch {
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
                broken.append(BrokenBox(id: id, url: url, message: Self.describeLoadError(error)))
            }
        }
        boxes = loaded.sorted { $0.config.createdAt < $1.config.createdAt }
        brokenBoxes = broken
        // 启动器被删掉或被覆盖时补回来，没有主人的清掉（读不出的盒子也算主人）
        let keep = Set(boxes.map(\.id) + brokenBoxes.map(\.id))
        let wanted = boxes.filter { $0.config.showInLaunchpad && !$0.config.isInstaller }
        Task {
            await Launcher.shared.removeOrphans(keeping: keep)
            for box in wanted where !(await Launcher.shared.hasLauncher(for: box.id)) {
                box.syncLauncher()
            }
        }
    }

    private static func describeLoadError(_ error: Error) -> String {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return L("缺少配置文件 box.json", "The configuration file box.json is missing") }
        if error is DecodingError {
            return L("配置文件 box.json 格式无法识别，可能来自更新版本的 MacBox 或已损坏",
                     "The configuration file box.json isn’t in a recognized format. It may be from a newer version of MacBox, or damaged.")
        }
        return L("无法读取配置文件 box.json：\(error.localizedDescription)",
                 "Couldn’t read the configuration file box.json: \(error.localizedDescription)")
    }

    func box(id: UUID) -> Box? { boxes.first { $0.id == id } }

    /// 同一个应用装了多份（比如两个网盘账号）时依次叫「夸克网盘」「夸克网盘 2」，和聚焦里的启动器同名；
    /// 否则卡片、提示（“「夸克网盘」正在运行”）里分不清是哪一个
    func uniqueName(_ name: String, excluding box: Box? = nil) -> String {
        let taken = Set(boxes.filter { $0 !== box }.map(\.config.name))
        var candidate = name, index = 2
        while taken.contains(candidate) {
            candidate = "\(name) \(index)"
            index += 1
        }
        return candidate
    }

    /// 上次 MacBox 异常退出时，可能有借出去的偏好设置没收回、盒子里的映像还挂着、
    /// 盒子里的程序还在运行（已不受管理，守卫也会结束它们）。先结束程序再收回设置，
    /// 否则它们会继续往刚恢复的本机设置里写
    private func recoverInterruptedSessions() async {
        let leases = boxes.map { PreferenceLease(box: $0.paths, prefixes: $0.config.preferencePrefixes) }
            .filter(\.isOutstanding)
        if !leases.isEmpty {
            for pid in await ProcessTable.pids(under: FileOps.realPath(AppPaths.boxes) + "/") { kill(pid, SIGKILL) }
        }
        for lease in leases {
            do { try await lease.checkOut() } catch {
                importError = L("无法恢复上次运行留下的偏好设置：\(error.localizedDescription)",
                                "Couldn’t restore preferences left over from the last session: \(error.localizedDescription)")
            }
        }
        for image in await DiskImage.attached(fromImagesUnder: FileOps.realPath(AppPaths.boxes)) {
            for device in image.devices.prefix(1) { await DiskImage.detach(device) }
        }
    }

    // MARK: - 导入

    func importItems(_ urls: [URL]) async {
        await ready()
        for url in urls {
            importStatus = L("正在读取「\(url.lastPathComponent)」…", "Reading “\(url.lastPathComponent)”…")
            do {
                // 先看类型再复制：不支持的大文件、文件夹不必整个复制进来才报错
                try PackageExtractor.checkSupported(url)
                let box = try await makeBox(from: url)
                selection = box.id
                importStatus = nil
                await afterImport(box)
            } catch {
                let message = L("无法添加「\(url.lastPathComponent)」：\(error.localizedDescription)",
                                "Couldn’t add “\(url.lastPathComponent)”: \(error.localizedDescription)")
                // 一次添加多个时，每个失败的都要列出来
                importError = importError.map { "\($0)\n\n\(message)" } ?? message
            }
        }
        importStatus = nil
    }

    private func makeBox(from url: URL) async throws -> Box {
        let id = UUID()
        let paths = BoxPaths.new(id: id)
        try AppPaths.ensure(paths.sourceDirectory)
        do {
            let source = paths.sourceDirectory.appending(path: url.lastPathComponent)
            // 来自其他卷（外接硬盘、网络位置）时是真正的复制，可能很慢
            try await Background.run { try FileOps.clone(url, to: source) }

            importStatus = L("正在取出 App…", "Extracting the app…")
            let extracted = try await PackageExtractor.extractApp(from: source, into: paths.appDirectory)
            let info = try AppInspector.info(of: extracted.app)

            importStatus = L("正在检查兼容性…", "Checking compatibility…")
            var issues = extracted.issues + (await AppInspector.scan(extracted.app))
            issues.insert(await AppInspector.verifyAndTrust(extracted.app), at: 0)
            var config = BoxConfig(id: id, name: uniqueName(info.name), bundleIdentifier: info.bundleIdentifier,
                                   version: info.version, appFolderName: extracted.app.lastPathComponent,
                                   sourceName: source.lastPathComponent)
            config.issues = issues
            config.isInstaller = AppInspector.looksLikeInstaller(info)
            config.preferencePrefixes = [AppInspector.preferencePrefix(for: info.bundleIdentifier)]
            config.showInLaunchpad = UserDefaults.standard.object(forKey: "defaultShowInLaunchpad") as? Bool ?? true
            try paths.save(config)

            importStatus = L("正在准备独立的钥匙串…", "Preparing a separate keychain…")
            try await BoxKeychain.prepare(paths)

            let box = Box(paths: paths, config: config)
            box.store = self
            boxes.append(box)
            await box.syncLauncher().value
            return box
        } catch {
            let boxURL = paths.url
            await Background.run { try? FileManager.default.removeItem(at: boxURL) }
            throw error
        }
    }

    private func afterImport(_ box: Box) async {
        let blocking = box.config.issues.filter { $0.severity == .needsVirtualMac }
        if !blocking.isEmpty {
            suggestVirtualMac(for: box, reasons: blocking.map {
                L("\($0.localizedTitle)：\($0.localizedDetail)", "\($0.localizedTitle): \($0.localizedDetail)")
            })
            return
        }
        // 拖进来的就是安装器：像在访达里双击一样直接运行它
        if box.config.isInstaller { await box.open() }
    }

    // MARK: - 兼容性

    func suggestVirtualMac(for box: Box, reasons: [String]) {
        guard box.config.runtime == .isolated else { return }
        switch CompatibilityPolicy.current {
        case .ask:
            prompt = CompatibilityPrompt(boxID: box.id, appName: box.config.name, reasons: reasons)
        case .switchAutomatically:
            box.config.runtime = .virtualMac
            box.notice = L("检测到兼容性问题，已按设置改用虚拟 Mac 运行。",
                           "Compatibility issues were found. Switched to Virtual Mac as set.")
        }
    }

    func openInVirtualMac(_ box: Box) async {
        let vm = VirtualMac.shared
        guard vm.config.installed else {
            box.notice = L("需要先在「虚拟 Mac」页完成一次性设置，之后这个应用就会在虚拟 Mac 中运行。",
                           "Finish the one-time setup on the “Virtual Mac” page first. After that, this app will run in Virtual Mac.")
            // 接下来显示的是虚拟 Mac 页，说明也要放在那里，否则只是突然换了一页
            vm.notice = L("「\(box.config.name)」设为在虚拟 Mac 中运行，需要先完成下面的一次性设置。",
                          "“\(box.config.name)” is set to run in Virtual Mac. Finish the one-time setup below first.")
            show(.virtualMac)
            return
        }
        await vm.sendToGuest([box.paths.source(box.config) ?? box.appURL])
        windowRequest = WindowRequest(window: .virtualMac)
        if vm.status == .stopped { await vm.start() }
    }

    /// 需要用户看到的情况（打不开等）：切到应用页并选中它。从聚焦打开时主窗口可能关着
    func reveal(_ box: Box) {
        selection = box.id
        show(.allApps)
    }

    /// 打开主窗口并切到指定页面
    func show(_ destination: Destination) {
        self.destination = destination
        NSApp?.activate() // 测试进程里没有 NSApp
        windowRequest = WindowRequest(window: .library)
    }

    // MARK: - 删除

    func delete(_ box: Box) throws {
        guard !box.isRunning else { throw MacBoxError(L("请先退出「\(box.config.name)」", "Quit “\(box.config.name)” first")) }
        guard !box.isBusy else { throw MacBoxError(L("「\(box.config.name)」正在处理其他操作，请稍候",
                                                         "“\(box.config.name)” is busy with another operation. Try again in a moment.")) }
        try FileManager.default.trashItem(at: box.paths.url, resultingItemURL: nil)
        box.retire()
        boxes.removeAll { $0.id == box.id }
        if selection == box.id { selection = nil }
    }

    /// 把读不出的盒子移到废纸篓（需要时可以从废纸篓找回）
    func deleteBroken(_ broken: BrokenBox) throws {
        try FileManager.default.trashItem(at: broken.url, resultingItemURL: nil)
        brokenBoxes.removeAll { $0.id == broken.id }
        Task { await Launcher.shared.remove(boxID: broken.id) }
    }

    // MARK: - 外部事件

    /// macbox://open/<id>（聚焦里的启动器）
    func handle(_ url: URL) {
        start()
        guard url.scheme == "macbox", url.host() == "open",
              let id = UUID(uuidString: url.lastPathComponent), let box = box(id: id) else { return }
        Task { await box.open() }
    }

    /// 守卫结束了一个沙盒外的进程：记录下来；如果是有人直接打开了盒子里的 App，改为在隔离中打开
    private func handleEscape(_ escape: EscapeGuard.Escape) {
        guard let box = boxes.first(where: { escape.owner.hasPrefix(FileOps.realPath($0.paths.url) + "/") }) else { return }
        let event = BlockEvent(kind: .escapedLaunch, target: escape.path)
        let mainExecutable = (try? AppInspector.info(of: box.appURL)).map { FileOps.realPath($0.executable) }
        if escape.path == mainExecutable, !box.isRunning, !isTerminating,
           Date().timeIntervalSince(lastRelaunch[box.id] ?? .distantPast) > 3 {
            lastRelaunch[box.id] = Date()
            // 新的运行会清空拦截记录，所以等它开始后再记
            Task {
                await box.open()
                box.record(event)
            }
        } else {
            box.record(event)
        }
    }

    var runningBoxes: [Box] { boxes.filter(\.isRunning) }
    /// 运行生命周期还没结束的（含启动中、收尾中）
    var liveBoxes: [Box] { boxes.filter(\.isLive) }

    /// 退出 MacBox 前让所有应用退出并完成收尾（最多等 10 秒）
    func quitAll() async {
        isTerminating = true
        for box in liveBoxes { box.quit() }
        // 等所有应用退出并完成收尾（收回偏好设置等），最多 10 秒
        let allQuit = Observations { self.liveBoxes.isEmpty }
        await withTaskGroup { group in
            group.addTask { for await empty in allQuit where empty { return } }
            group.addTask { try? await Task.sleep(for: .seconds(10)) }
            await group.next()
            group.cancelAll()
        }
    }
}
