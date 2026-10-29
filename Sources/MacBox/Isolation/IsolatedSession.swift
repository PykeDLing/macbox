import AppKit
import Foundation

/// 一次本机隔离运行。
///
/// 整个生命周期是一个结构化的 `run`：准备 → 借出偏好设置 → 解锁 App、在沙盒中启动 → 等所有进程退出 → 收尾。
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
    /// 所有进程都已退出：之后的强制结束不能波及同一盒子里新开的会话
    private var exited = false
    /// 还没解析完的服务器名字（见 watchConnections）
    private var pendingNames = 0

    struct Outcome {
        /// 安装器下载的完整安装包（在盒子里）。只有在线安装器才找
        var downloadedPackages: [URL] = []
        /// 主进程的退出码（被信号结束时为 128 + 信号）。主进程启动不了时 sandbox-exec 以 71 退出
        var mainExitStatus: Int32?
        /// 主进程从启动到退出运行了多久（秒）
        var mainRanFor: TimeInterval = 0
        /// 收回偏好设置失败的原因。日志还在，下次启动 MacBox 时会再次尝试
        var preferencesReturnError: String?
        /// 这次写下的文件、改了的设置、写在盒子外的设置（对比运行前后，见 RunSnapshot）
        var changes: RunChanges?
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
    /// - onActivity：运行期间陆续得到的记录：拦截、启动的程序、连到的服务器（运行报告用）
    static func run(paths: BoxPaths, config: BoxConfig,
                    onStart: (IsolatedSession) -> Void,
                    onActivity: @escaping (RunActivity) -> Void) async throws -> Outcome {
        let plan = try await prepare(paths, config: config)
        try await BoxKeychain.prepare(paths)
        // 运行前的样子，退出后对比出这次写了哪些文件、改了哪些设置（运行报告）。主目录、钥匙串由 MacBox 准备好之后再记。
        // 文件多的 App 要走一会儿，和借出偏好设置、等日志流同时做，不拖慢启动
        async let files = RunSnapshot.files(of: paths, config: config)

        let lease = PreferenceLease(box: paths, prefixes: config.preferencePrefixes)
        try await lease.checkIn() // 失败时自己回滚
        // 正常结束时，所有进程一退出就先收回（见下面）；这里是出错、取消时的保底。收回可以重复调用
        defer { await returnPreferences(lease) }
        let preferences = await RunSnapshot.savedPreferences(of: paths, config: config)

        // 先订阅拦截记录、等日志流就绪，再启动 App：很多 App 一启动就注册自启动、写系统目录
        let sessionPID = SessionPID()
        let events = await ViolationMonitor.events(boxPrefix: FileOps.realPath(paths.url), processNames: plan.processNames,
                                                  installer: config.isInstaller, session: sessionPID)
        // 写「下载」和你选的文件夹的记录留在这里，退出后和主目录的改动一起汇总
        let shared = SharedWrites(folders: WritableFolders.granted(config))
        let monitor = Task {
            for await activity in events {
                if case .wroteShared(let path, let operation) = activity {
                    shared.note(path, operation: operation)
                } else {
                    onActivity(activity)
                }
            }
        }
        defer { monitor.cancel() }

        // 你真实的偏好设置目录最后列：离启动越近，算到这个应用头上的别的程序写的越少（见 SystemPreferenceFiles）
        let before = RunSnapshot(files: await files, preferences: preferences, system: await RunSnapshot.systemPreferences())

        let profile = SandboxProfile.make(box: paths, config: config)
        try? profile.write(to: paths.sandboxProfile, atomically: true, encoding: .utf8) // 便于排查
        var options = ChildProcess.Options()
        options.environment = environment(for: paths)
        options.newProcessGroup = true
        options.disclaimResponsibility = true
        // App 平时是锁着的（见 AppLock），启动前一刻才解锁；所有进程退出后、或者启动失败时再锁上
        let app = paths.app(config)
        try await unlock(app, executable: plan.executable, paths: paths)
        defer { await lock(app, paths: paths) }
        let process = try ChildProcess.spawn("/usr/bin/sandbox-exec", ["-p", profile, plan.executable] + plan.arguments,
                                             options: options)
        EscapeGuard.shared.register(session: process.pid)
        defer { EscapeGuard.shared.unregister(session: process.pid) }
        sessionPID.set(process.pid)

        let session = IsolatedSession(process: process, paths: paths, appURL: app)
        onStart(session)
        // 不联网时连不上任何地方，不用看
        let connections = Task { if config.allowsNetwork { await session.watchConnections(onActivity) } }
        defer { connections.cancel() }

        let main = await session.waitUntilAllExited()
        connections.cancel()
        // 先把偏好设置还回去，再做可能较慢的收尾（卸载映像、在主目录里找安装包），尽量缩短借出的时间：
        // 这期间 MacBox 可能正在退出，来不及做完的收尾下次还能补，借出的设置留在系统里却会被本机的 App 读到
        let preferencesError = await returnPreferences(lease)
        await session.cleanUpSystemTraces()
        let changes = await before.changes(paths, config: config, preferencesReturned: preferencesError == nil,
                                           shared: shared.areas)
        await session.finishNameLookups(timeout: .seconds(2))
        return Outcome(downloadedPackages: config.isInstaller ? await session.downloadedPackages() : [],
                       mainExitStatus: main.status, mainRanFor: main.ranFor, preferencesReturnError: preferencesError,
                       changes: changes)
    }

    /// 主进程已退出（会话可能还在：辅助进程还在运行）
    var mainHasExited: Bool { process.hasExited }

    /// 让窗口回到前台。返回 false 表示没有可以切过去的 App（例如主进程已退出、只剩后台程序）。
    /// 协作式激活下，只有前台的 App 让出前台，别的 App 的激活请求才会被接受：MacBox 自己在前台时
    /// （在 MacBox 里点的、聚焦里的启动器把 MacBox 叫到了前台）先让给它
    @discardableResult
    func activate() -> Bool {
        guard let target = activationTarget() else { return false }
        NSApp?.yieldActivation(to: target)
        target.activate()
        return true
    }

    /// 切到前台时切到哪个 App。主进程不是普通的带界面的 App 时（启动器式的主程序、在后台运行的辅助程序，
    /// 或者已经退出、重启以生效后换了新实例），是盒子里还在运行的普通 App；一个都没有时才是主进程
    func activationTarget() -> NSRunningApplication? {
        let main = process.hasExited ? nil : NSRunningApplication(processIdentifier: mainPID)
        if let main, main.activationPolicy == .regular { return main }
        let boxRoot = boxRoot
        let regular = NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular && app.bundleURL.map { FileOps.realPath($0).hasPrefix(boxRoot) } == true
        }
        return regular ?? main
    }

    /// 请求退出，像 ⌘Q 一样。只是请求：App 可能弹出“是否存储”，用户也可能点“取消”继续使用，
    /// 所以不会到时间就自动强制结束（会丢掉没存的内容，写到一半的数据库会损坏）；强制结束用 forceQuit()。
    /// 可以再次调用，每次都重新请求
    func terminate() {
        guard !exited else { return }
        if !process.hasExited {
            // 主进程还在：只请求它退出，由它结束自己的辅助进程（辅助进程里可能就有没存的内容）。
            if let app = NSRunningApplication(processIdentifier: mainPID), app.terminate() { return }
            // 不是带界面的 App（命令行程序、脚本）时给整组发 SIGTERM，和在终端里结束它一样；
            // 离开了进程组的盒子程序（调用过 setsid 的、以 detached 方式启动的辅助程序）收不到，单独请求。
            // 组里的不再单独发：带 trap 的脚本每收到一次都会执行一遍
            process.signal(SIGTERM)
            requestQuit { ProcessTable.lineage(of: $0)?.group != $1 }
            return
        }
        // 主进程已退出、只剩辅助进程：带界面的（比如重启以生效后的新实例）请求退出，其余的发 SIGTERM
        requestQuit { _, _ in true }
    }

    /// 请求会话里 include 选中的进程退出（参数：进程、会话的进程组号）：带界面的请求退出，其余的发 SIGTERM
    private func requestQuit(_ include: @escaping @Sendable (pid_t, pid_t) -> Bool) {
        Task {
            for pid in await Self.members(boxRoot: boxRoot, group: mainPID) where !exited && include(pid, mainPID) {
                if let app = NSRunningApplication(processIdentifier: pid), app.terminate() { continue }
                kill(pid, SIGTERM)
            }
        }
    }

    /// 强制结束会话里的所有进程（用户确认后才调用：没存的内容会丢失）
    func forceQuit() async {
        guard !exited else { return }
        process.signal(SIGKILL) // 发给整个进程组，主进程已退出也照样发
        for pid in await Self.members(boxRoot: boxRoot, group: mainPID) where !exited { kill(pid, SIGKILL) }
    }

    /// 本次运行期间在盒子主目录里新出现的安装包（排除「下载」文件夹里用户自己的文件）
    func downloadedPackages() async -> [URL] {
        await Self.findPackages(in: [paths.home, paths.tmp], skipping: FileOps.realPath(paths.downloads),
                                since: startedAt.addingTimeInterval(-2))
    }

    // MARK: - 连接

    /// 定时看一眼会话里的进程连了哪些服务器（见 ConnectionMonitor），第一次看到的交给 onActivity，公网地址再反向解析名字。
    /// 刚启动时连得最多，连接也短（WKWebView 加载完一个页面，一秒内就断开了）：前 15 秒每半秒看一次，
    /// 一分钟内每秒一次，之后每 3 秒一次。看一次约 30 毫秒 CPU。任务取消时停止
    private func watchConnections(_ onActivity: @escaping (RunActivity) -> Void) async {
        var seen: Set<String> = []
        var looked: Set<String> = []
        let started = ContinuousClock.now
        while !Task.isCancelled {
            for contact in await ConnectionMonitor.connections(of: await networkMembers()) where seen.insert(contact.id).inserted {
                onActivity(.connected(contact))
                guard contact.scope == .internet, looked.insert(contact.address).inserted else { continue }
                pendingNames += 1
                Task {
                    if let name = await ConnectionMonitor.reverseName(contact.address) {
                        onActivity(.named(address: contact.address, name: name))
                    }
                    pendingNames -= 1
                }
            }
            let elapsed = ContinuousClock.now - started
            try? await Task.sleep(for: elapsed < .seconds(15) ? .milliseconds(500) : elapsed < .seconds(60) ? .seconds(1) : .seconds(3))
        }
    }

    /// 要看连接的进程：会话里的（见 members），加上守卫记下的、系统代它启动的 XPC 服务（WebKit 的网络进程替 WKWebView 联网）
    private func networkMembers() async -> [pid_t] {
        var pids = await Self.members(boxRoot: boxRoot, group: mainPID)
        pids.formUnion(EscapeGuard.shared.members(of: mainPID))
        return Array(pids)
    }

    /// 等还没解析完的服务器名字，最多等 timeout：报告里尽量都有名字。解析不出的不会一直等（DNS 超时要好几秒）
    private func finishNameLookups(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while pendingNames > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 生命周期内部

    /// 主进程退出后，再等会话里的其他进程全部结束（连续两次检查都没有）。返回主进程的退出码和运行时长
    private func waitUntilAllExited() async -> (status: Int32, ranFor: TimeInterval) {
        let status = await process.waitForExit()
        let ranFor = Date().timeIntervalSince(startedAt)
        var idleRounds = 0
        while idleRounds < 2 {
            try? await Task.sleep(for: .milliseconds(700))
            idleRounds = await Self.members(boxRoot: boxRoot, group: mainPID).isEmpty ? idleRounds + 1 : 0
        }
        exited = true
        return (status, ranFor)
    }

    /// 会话里还在运行的进程：
    /// - 可执行文件在盒子里的；
    /// - 会话进程组里、在沙盒中的：App 启动的系统程序和脚本（sh、python、curl、defaults…）不在盒子里，
    ///   它们还在运行时会话就不能结束——偏好设置收回之后它们写的设置会落进你真实的偏好设置。
    ///   进程组号就是主进程的 pid，组里还有进程时内核不会把它分给新进程，所以组里的都是这次会话的
    @concurrent
    private static func members(boxRoot: String, group: pid_t) async -> Set<pid_t> {
        var pids = Set(ProcessTable.processes(under: boxRoot))
        for pid in ProcessTable.pids(inGroup: group) {
            guard let lineage = ProcessTable.lineage(of: pid), !lineage.isZombie, ProcessTable.isSandboxed(pid) else { continue }
            pids.insert(pid)
        }
        return pids
    }

    /// 卸载安装器挂载的卷；撤销系统对盒子里 App 的登记，以免其他途径绕过 MacBox 直接打开它
    private func cleanUpSystemTraces() async {
        for image in await DiskImage.attached(fromImagesUnder: FileOps.realPath(paths.url)) {
            for device in image.devices.prefix(1) { await DiskImage.detach(device) }
        }
        await EscapeGuard.refreshVolumes()
        await AppRegistration.unregister(appURL) // App 运行时可能经由系统启动了包里的辅助 App，它们也会被登记
    }

    /// 收回偏好设置；返回失败的原因
    @discardableResult
    private static func returnPreferences(_ lease: PreferenceLease) async -> String? {
        do {
            try await lease.checkOut()
            return nil
        } catch {
            // 日志还在，下次启动 MacBox 时会再次尝试
            NSLog("MacBox: 收回偏好设置失败：\(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// 解锁 App，确认主程序能执行；失败时重新锁上再抛出
    @concurrent
    private static func unlock(_ app: URL, executable: String, paths: BoxPaths) async throws {
        try checkLayout(paths, app: app) // 准备时查过，这之间又借出了偏好设置、准备了钥匙串；只是几次 lstat，解锁前再查一次
        do {
            try AppLock.unlock(app)
            guard access(executable, X_OK) == 0 else {
                let reason = String(cString: strerror(errno)), name = (executable as NSString).lastPathComponent
                throw MacBoxError(L("无法运行 App 的主程序「\(name)」：\(reason)", "Couldn’t run the app’s executable “\(name)”: \(reason)"))
            }
        } catch {
            try? AppLock.lock(app)
            throw error
        }
    }

    /// 重新锁上。App 运行期间改得到 App 文件夹里的内容，可能把 App 换成了指向别处的符号链接（比如指向
    /// /Applications 里你自己装的同名 App）：这时不锁，顺着链接会去掉别处 App 的执行权限
    @concurrent
    private static func lock(_ app: URL, paths: BoxPaths) async {
        do {
            try checkLayout(paths, app: app)
            try AppLock.lock(app)
        } catch {
            NSLog("MacBox: 无法锁上 App：\(error.localizedDescription)")
        }
    }

    /// MacBox 在沙盒外要读写的盒子文件夹（BoxPaths.skeleton）不能是符号链接，App 必须真的在盒子的 App 文件夹里。
    /// 现在的沙盒规则不许 App 删除、替换这些文件夹（见 SandboxProfile），旧版的规则许可：那时被换成指向别处的链接的，
    /// 顺着链接准备主目录、替换钥匙串的链接、给 App 上锁解锁，改到的都是盒子以外你自己的文件。
    /// App 包本身在 App 文件夹里面，运行期间仍然可能被换掉，所以每次上锁前也要查
    nonisolated static func checkLayout(_ paths: BoxPaths, app: URL) throws {
        if let replaced = paths.skeleton.first(where: { isSymlink($0.path) }) {
            let name = replaced.lastPathComponent
            throw MacBoxError(L("盒子里的「\(name)」文件夹被换成了指向别处的链接。为了不改动盒子以外的文件，这个应用不会打开。可以删除它再重新添加。",
                                "The “\(name)” folder in this box was replaced with a link to another location. To avoid changing files outside the box, the app won’t open. Try deleting it and adding it again."))
        }
        // App 不存在时由读取 App 信息的那一步报告
        let folder = FileOps.realPath(paths.url) + "/" + paths.appDirectory.lastPathComponent + "/"
        guard !FileManager.default.fileExists(atPath: app.path) || FileOps.realPath(app).hasPrefix(folder) else {
            throw MacBoxError(L("盒子里的 App 被换成了指向别处的链接。为了不改动盒子以外的文件，这个应用不会打开。可以删除它再重新添加。",
                                "The app in this box was replaced with a link to another location. To avoid changing files outside the box, the app won’t open. Try deleting it and adding it again."))
        }
    }

    /// 路径本身是符号链接（不跟随最后一级；URL 的 path 不带结尾的 /，带了就会跟随）
    private nonisolated static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
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

    /// 读取 App 信息、检查主程序、准备主目录、收集可执行文件名（都要读写磁盘，在后台执行）
    @concurrent
    private static func prepare(_ paths: BoxPaths, config: BoxConfig) async throws -> LaunchPlan {
        let app = paths.app(config)
        try checkLayout(paths, app: app)
        let info = try AppInspector.info(of: app)
        try preflight(info.executable)
        try prepareHome(paths, config: config)
        return LaunchPlan(executable: info.executable.path,
                          arguments: AppInspector.launchArguments(for: app),
                          processNames: executableNames(in: app))
    }

    /// 主程序不存在、不是程序、#! 脚本的解释器不存在时，sandbox-exec 只会报一行错就退出，
    /// 用户看到的是“点了没反应”。在借出偏好设置之前先查出来，给出原因
    nonisolated static func preflight(_ executable: URL) throws {
        let name = executable.lastPathComponent
        var info = stat()
        guard stat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MacBoxError(L("找不到 App 的主程序「\(name)」，App 可能已损坏。可以删除它再重新添加。",
                                "The app’s executable “\(name)” is missing. The app may be damaged. Try deleting it and adding it again."))
        }
        // 上锁的 App 没有执行权限（启动前才解锁），按内容判断解锁后能不能执行
        guard access(executable.path, X_OK) == 0 || AppLock.looksExecutable(executable.path) else {
            throw MacBoxError(L("App 的主程序「\(name)」不是可以运行的程序，App 可能已损坏。",
                                "The app’s executable “\(name)” isn’t a program that can run. The app may be damaged."))
        }
        if let interpreter = interpreter(of: executable), access(interpreter, X_OK) != 0 {
            throw MacBoxError(L("App 的主程序是脚本，需要「\(interpreter)」才能运行，但这台 Mac 上没有它。",
                                "The app’s executable is a script that needs “\(interpreter)” to run, but it isn’t on this Mac."))
        }
    }

    /// #! 脚本第一行指定的解释器
    private nonisolated static func interpreter(of executable: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: executable.path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512), head.starts(with: Array("#!".utf8)) else { return nil }
        let line = String(decoding: head.dropFirst(2).prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    /// 「下载」不共享时，盒子自己的下载文件夹在共享期间收在主目录里的这个名字下
    /// （App、「在访达中显示」、数据大小、清除数据都看得到），取消共享时放回原处。两种语言的名字都认
    nonisolated static let keptDownloadsNames = ["盒子里的下载", "Box Downloads"]

    nonisolated static func prepareHome(_ paths: BoxPaths, config: BoxConfig) throws {
        for sub in ["Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Keychains",
                    "Desktop", "Documents"] {
            try AppPaths.ensure(paths.home.appending(path: sub, directoryHint: .isDirectory))
        }
        try AppPaths.ensure(paths.tmp)
        try adoptLegacyDownloads(paths)
        // 「下载」：共享时指向你真实的下载文件夹，否则是盒子里的独立文件夹
        let manager = FileManager.default
        let downloads = paths.downloads
        let realDownloads = AppPaths.realHome.appending(path: "Downloads")
        if config.shareDownloads {
            if !FileOps.isSymlink(downloads) {
                if manager.fileExists(atPath: downloads.path) {
                    // 之前留在盒子里的下载文件收起来，不被覆盖
                    if isEmptyFolder(downloads) {
                        try manager.removeItem(at: downloads)
                    } else {
                        try manager.moveItem(at: downloads, to: FileOps.uniqueURL(in: paths.home, name: L("盒子里的下载", "Box Downloads")))
                    }
                }
                try manager.createSymbolicLink(at: downloads, withDestinationURL: realDownloads)
            }
        } else {
            if FileOps.isSymlink(downloads) { try manager.removeItem(at: downloads) }
            // 共享期间收起来的放回原处（URL 会缓存“是符号链接”，删掉之后不能再用 FileOps.isSymlink 判断）
            if let kept = keptDownloads(in: paths.home) {
                if isEmptyFolder(downloads) { try manager.removeItem(at: downloads) }
                if !manager.fileExists(atPath: downloads.path) { try manager.moveItem(at: kept, to: downloads) }
            }
            try AppPaths.ensure(downloads)
        }
    }

    /// 旧版开启共享时，把盒子自己的下载文件移到了盒子根目录（Downloads、Downloads 2…），
    /// App、「在访达中显示」、数据大小、清除数据都看不到它们。移进主目录，和新版收起来的放在一起
    private nonisolated static func adoptLegacyDownloads(_ paths: BoxPaths) throws {
        for item in FileOps.contents(of: paths.url) where !FileOps.isSymlink(item) {
            let name = item.lastPathComponent
            guard name == "Downloads" || name.wholeMatch(of: /Downloads \d+/) != nil,
                  (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if isEmptyFolder(item) {
                try FileManager.default.removeItem(at: item)
            } else {
                try FileManager.default.moveItem(at: item, to: FileOps.uniqueURL(in: paths.home, name: L("盒子里的下载", "Box Downloads")))
            }
        }
    }

    private nonisolated static func keptDownloads(in home: URL) -> URL? {
        keptDownloadsNames.map { home.appending(path: $0, directoryHint: .isDirectory) }.first { url in
            !FileOps.isSymlink(url) && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// 空文件夹（访达自己放的 .DS_Store、.localized 不算内容）。不是文件夹时为 false
    private nonisolated static func isEmptyFolder(_ url: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return items.allSatisfy { [".DS_Store", ".localized"].contains($0) }
    }

    /// App 包内可执行文件的名字（主程序和各种 Helper），用于识别日志里已经退出的进程。
    /// 不看框架里面：Sparkle 等框架自带的 Installer、Updater、Autoupdate 名字太普通，本机其他 App 也有
    private nonisolated static func executableNames(in app: URL) -> Set<String> {
        var names: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "framework" { enumerator?.skipDescendants() }
            if item.deletingLastPathComponent().lastPathComponent == "MacOS" { names.insert(item.lastPathComponent) }
        }
        return names
    }
}
