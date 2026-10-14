import AppKit
import Foundation

/// 一次本机隔离运行。
///
/// 整个生命周期是一个结构化的 `run`：准备 → 借出偏好设置 → 在沙盒中启动 → 等所有进程退出 → 收尾。
/// 每借用一样系统资源，紧接着用 `defer` 登记归还（Swift 6.4 起 defer 里可以 await），
/// 所以无论在哪一步失败、被取消，已借出的东西都按相反顺序归还，不会有半途而废的状态。
final class IsolatedSession {
    let mainPID: pid_t
    let startedAt = Date()
    private let process: ChildProcess
    private let paths: BoxPaths
    private let appURL: URL
    /// 盒子目录的真实路径（带结尾的 /），用于在进程表里找盒子里的进程
    private let boxRoot: String
    private var terminating = false
    /// 所有进程都已退出：之后的强制结束不能波及同一盒子里新开的会话
    private var exited = false

    struct Outcome {
        /// 安装器下载的完整安装包（在盒子里）
        var downloadedPackages: [URL] = []
    }

    /// 启动前在后台准备好的内容
    private nonisolated struct LaunchPlan: Sendable {
        let executable: String
        let arguments: [String]
        let processNames: Set<String>
    }

    private init(process: ChildProcess, paths: BoxPaths, appURL: URL) {
        self.process = process
        self.mainPID = process.pid
        self.paths = paths
        self.appURL = appURL
        self.boxRoot = FileOps.realPath(paths.url) + "/"
    }

    /// 运行 App，直到它和它的辅助进程全部退出、收尾完成才返回。
    /// - onStart：App 已启动，交出会话（切到前台、请求退出）
    /// - onBlock：新的拦截记录
    static func run(paths: BoxPaths, config: BoxConfig,
                    onStart: (IsolatedSession) -> Void,
                    onBlock: @escaping (BlockEvent) -> Void) async throws -> Outcome {
        let plan = try await prepare(paths, config: config)
        try await BoxKeychain.prepare(paths)

        let lease = PreferenceLease(box: paths, prefixes: config.preferencePrefixes)
        try await lease.checkIn() // 失败时自己回滚
        defer { await returnPreferences(lease) }

        // 先订阅拦截记录、等日志流就绪，再启动 App：很多 App 一启动就注册自启动、写系统目录
        let events = await ViolationMonitor.events(boxPrefix: FileOps.realPath(paths.url), processNames: plan.processNames,
                                                  installer: config.isInstaller)
        let monitor = Task {
            for await event in events { onBlock(event) }
        }
        defer { monitor.cancel() }

        let profile = SandboxProfile.make(box: paths, config: config)
        try? profile.write(to: paths.url.appending(path: "sandbox.sb"), atomically: true, encoding: .utf8) // 便于排查
        var options = ChildProcess.Options()
        options.environment = environment(for: paths)
        options.newProcessGroup = true
        options.disclaimResponsibility = true
        let process = try ChildProcess.spawn("/usr/bin/sandbox-exec", ["-p", profile, plan.executable] + plan.arguments,
                                             options: options)
        EscapeGuard.shared.register(session: process.pid)
        defer { EscapeGuard.shared.unregister(session: process.pid) }

        let session = IsolatedSession(process: process, paths: paths, appURL: paths.app(config))
        onStart(session)

        await session.waitUntilAllExited()
        await session.cleanUpSystemTraces()
        return Outcome(downloadedPackages: await session.downloadedPackages())
    }

    /// 让窗口回到前台
    func activate() {
        NSRunningApplication(processIdentifier: mainPID)?.activate()
    }

    /// 请求退出（像 ⌘Q 一样），5 秒后仍未退出则强制结束盒子里的所有进程
    func terminate() {
        guard !terminating else { return }
        terminating = true
        if let app = NSRunningApplication(processIdentifier: mainPID) {
            app.terminate()
        } else {
            process.signal(SIGTERM)
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard !exited else { return }
            await forceKill()
        }
    }

    func forceKill() async {
        guard !exited else { return }
        process.signal(SIGKILL)
        for pid in await ProcessTable.pids(under: boxRoot) { kill(pid, SIGKILL) }
    }

    /// 本次运行期间在盒子主目录里新出现的安装包（排除「下载」文件夹里用户自己的文件）
    func downloadedPackages() async -> [URL] {
        await Self.findPackages(in: [paths.home, paths.tmp], skipping: FileOps.realPath(paths.downloads),
                                since: startedAt.addingTimeInterval(-2))
    }

    // MARK: - 生命周期内部

    /// 主进程退出后，再等盒子里的辅助进程全部结束（连续两次检查都没有）
    private func waitUntilAllExited() async {
        _ = await process.waitForExit()
        var idleRounds = 0
        while idleRounds < 2 {
            try? await Task.sleep(for: .milliseconds(700))
            idleRounds = await ProcessTable.pids(under: boxRoot).isEmpty ? idleRounds + 1 : 0
        }
        exited = true
    }

    /// 卸载安装器挂载的卷；撤销系统对盒子里 App 的登记，以免其他途径绕过 MacBox 直接打开它
    private func cleanUpSystemTraces() async {
        for image in await DiskImage.attached(fromImagesUnder: FileOps.realPath(paths.url)) {
            for device in image.devices.prefix(1) { await DiskImage.detach(device) }
        }
        await EscapeGuard.refreshVolumes()
        _ = try? await Shell.run(Shell.lsregister, ["-u", appURL.path])
    }

    private static func returnPreferences(_ lease: PreferenceLease) async {
        do {
            try await lease.checkOut()
        } catch {
            // 日志还在，下次启动 MacBox 时会再次尝试
            NSLog("MacBox: 收回偏好设置失败：\(error.localizedDescription)")
        }
    }

    private static func environment(for paths: BoxPaths) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = paths.home.path
        environment["HOME"] = home
        environment["CFFIXED_USER_HOME"] = home
        environment["TMPDIR"] = paths.tmp.path + "/"
        // MacBox 自己的启动信息不传下去：XPC_SERVICE_NAME 是 launchd 给 MacBox 的服务名，
        // 盒子里的 App 带着它会被当成 MacBox 的一部分；MACBOX_DATA_ROOT 只给 MacBox 自己用
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "MACBOX_DATA_ROOT"] { environment.removeValue(forKey: key) }
        return environment
    }

    @concurrent
    private static func findPackages(in roots: [URL], skipping skip: String, since: Date) async -> [URL] {
        var found: [(url: URL, size: Int64)] = []
        for root in roots {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
            while let item = enumerator?.nextObject() as? URL {
                if FileOps.realPath(item).hasPrefix(skip) {
                    enumerator?.skipDescendants()
                    continue
                }
                if item.pathExtension == "app" { enumerator?.skipDescendants() }
                guard PackageExtractor.supportedExtensions.contains(item.pathExtension.lowercased()),
                      let created = FileOps.creationDate(of: item), created >= since else { continue }
                let size = FileOps.allocatedSize(of: item)
                if size > 1 << 20 { found.append((item, size)) }
            }
        }
        return found.sorted { $0.size > $1.size }.map(\.url)
    }

    /// 读取 App 信息、准备主目录、收集可执行文件名（都要读写磁盘，在后台执行）
    @concurrent
    private static func prepare(_ paths: BoxPaths, config: BoxConfig) async throws -> LaunchPlan {
        let app = paths.app(config)
        let info = try AppInspector.info(of: app)
        try prepareHome(paths, config: config)
        return LaunchPlan(executable: info.executable.path,
                          arguments: AppInspector.launchArguments(for: app),
                          processNames: executableNames(in: app))
    }

    private nonisolated static func prepareHome(_ paths: BoxPaths, config: BoxConfig) throws {
        for sub in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Keychains",
                    "Desktop", "Documents"] {
            try AppPaths.ensure(paths.home.appending(path: sub, directoryHint: .isDirectory))
        }
        try AppPaths.ensure(paths.tmp)
        // 「下载」：共享时指向你真实的下载文件夹，否则是盒子里的独立文件夹
        let downloads = paths.downloads
        let realDownloads = AppPaths.realHome.appending(path: "Downloads")
        if config.shareDownloads {
            if !FileOps.isSymlink(downloads) {
                if FileManager.default.fileExists(atPath: downloads.path) {
                    // 把之前留在盒子里的下载文件移到盒子根目录，避免被覆盖
                    try FileManager.default.moveItem(at: downloads, to: FileOps.uniqueURL(in: paths.url, name: "Downloads"))
                }
                try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: realDownloads)
            }
        } else if FileOps.isSymlink(downloads) || !FileManager.default.fileExists(atPath: downloads.path) {
            try FileOps.removeIfExists(downloads)
            try AppPaths.ensure(downloads)
        }
    }

    /// App 包内所有可执行文件的名字（主程序和各种 Helper），用于识别日志里的进程
    private nonisolated static func executableNames(in app: URL) -> Set<String> {
        var names: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if item.deletingLastPathComponent().lastPathComponent == "MacOS" { names.insert(item.lastPathComponent) }
        }
        return names
    }
}
