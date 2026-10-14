import Foundation
import Synchronization

/// 被拦截的一次行为（来自系统日志里的沙盒拒绝记录）
nonisolated struct BlockEvent: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case autostart, backgroundService, systemInstall, escapedLaunch, diskMount, personalFiles, privacyRead, notification, appleEvent, other

        var title: String {
            switch self {
            case .escapedLaunch: L("在沙盒外启动程序", "Launch a program outside the sandbox")
            case .diskMount: L("挂载磁盘映像", "Mount a disk image")
            case .autostart: L("注册开机自启动", "Register to open at login")
            case .backgroundService: L("注册后台服务", "Register a background service")
            case .systemInstall: L("写入系统目录", "Write to system folders")
            case .personalFiles: L("写入你的个人文件夹", "Write to your personal folders")
            case .privacyRead: L("读取私人数据", "Read private data")
            case .notification: L("发送通知", "Send notifications")
            case .appleEvent: L("控制其他 App", "Control other apps")
            case .other: L("其他系统操作", "Other system operations")
            }
        }

        /// 这类行为被挡住后，软件的功能可能不完整，建议改用虚拟 Mac
        /// 开机自启被挡只是“不再自启”，不影响使用，所以不算
        var suggestsVirtualMac: Bool { [.backgroundService, .systemInstall].contains(self) }
    }

    let kind: Kind
    let target: String
    var count = 1
    var lastSeen = Date()
    var id: String { "\(kind.rawValue)|\(target)" }
}

/// 会话主进程的 pid：订阅拦截记录（见 ViolationMonitor.events）要在启动 App 之前，启动后再填上
nonisolated final class SessionPID: Sendable {
    private let value = Mutex<pid_t?>(nil)

    init() {}

    func set(_ pid: pid_t) {
        value.withLock { $0 = pid }
    }

    var pid: pid_t? { value.withLock { $0 } }
}

/// 系统日志里的沙盒拒绝记录。
///
/// 整个 MacBox 只开一个 `log stream`：第一个订阅者到来时启动，最后一个离开时结束，
/// 每行日志只解析一次，再按盒子分发。同时运行多个应用时不会有多份日志进程各自解析全部日志。
///
/// 这是**尽力而为**的信号：内核对沙盒拒绝报告做全局限流（其他进程大量报告时，盒子里的报告会被丢弃），
/// 所以“没有记录”不代表“没有被拦截”。只能用于提示，不能作为安全或流程判断的唯一依据。
nonisolated enum ViolationMonitor {
    /// 本盒子进程的拦截记录；停止迭代（任务取消）时退订。
    /// 返回前等日志流真正开始输出（最多 3 秒），App 启动时的拦截不会因为日志进程还没就绪而漏掉
    /// - processNames：盒子里各个可执行文件的名字，只用来认已经退出的进程
    /// - installer：盒子里是在线安装器（它的规则禁止挂载磁盘映像，见 SandboxProfile）
    /// - session：会话主进程。订阅要在启动 App 之前，所以先给一个空的，启动后再填上
    static func events(boxPrefix: String, processNames: Set<String>, installer: Bool = false,
                       session: SessionPID) async -> AsyncStream<BlockEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BlockEvent.self)
        let parser = Parser(boxPrefix: boxPrefix, processNames: processNames, installer: installer,
                            home: FileOps.realPath(AppPaths.realHome), session: session)
        let id = UUID()
        continuation.onTermination = { _ in Task { await hub.unsubscribe(id) } }
        await hub.subscribe(id, parser: parser, continuation: continuation)
        await hub.waitUntilStreaming(timeout: .seconds(3))
        return stream
    }

    /// 日志里的进程名是否就是这个可执行文件。内核只记进程名的前 32 个字节
    /// （"Some Long App Name Helper (Renderer)" 记成 "Some Long App Name Helper (Rende"），
    /// 截断处可能落在一个汉字中间，所以比较 UTF-8 字节、允许末尾少 3 个字节。
    /// 不用前缀匹配：短名字（比如 "main"）会把其他程序的拦截记录算到盒子头上
    static func loggedName(_ logged: String, matches executable: String) -> Bool {
        if logged == executable { return true }
        var cut = Substring(logged)
        while cut.hasSuffix("\u{FFFD}") { cut.removeLast() } // 被截断的半个字
        let limit = 32
        return executable.utf8.count > limit && (limit - 3...limit).contains(cut.utf8.count)
            && executable.utf8.starts(with: cut.utf8)
    }

    private static let hub = Hub()

    private actor Hub {
        private var subscribers: [UUID: (parser: Parser, continuation: AsyncStream<BlockEvent>.Continuation)] = [:]
        private var reader: Task<Void, Never>?
        private var process: ChildProcess?
        /// 订阅还没登记就已退订的（两个 Task 到达顺序不定）
        private var departed: Set<UUID> = []
        /// 当前日志进程已开始输出（log stream 先输出一行 "Filtering the log data…"）
        private var streaming = false
        private var streamingWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        func waitUntilStreaming(timeout: Duration) async {
            guard !streaming, process != nil else { return }
            let id = UUID()
            let timer = Task {
                try? await Task.sleep(for: timeout)
                self.resumeWaiter(id)
            }
            await withCheckedContinuation { streamingWaiters[id] = $0 }
            timer.cancel()
        }

        private func resumeWaiter(_ id: UUID) {
            streamingWaiters.removeValue(forKey: id)?.resume()
        }

        private func markStreaming() {
            guard !streaming else { return }
            streaming = true
            let waiters = streamingWaiters.values
            streamingWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func subscribe(_ id: UUID, parser: Parser, continuation: AsyncStream<BlockEvent>.Continuation) {
            guard departed.remove(id) == nil else { return }
            subscribers[id] = (parser, continuation)
            if reader == nil { startReading() }
        }

        func unsubscribe(_ id: UUID) {
            guard subscribers.removeValue(forKey: id) != nil else {
                departed.insert(id)
                return
            }
            if subscribers.isEmpty { stopReading() }
        }

        private func startReading() {
            var options = ChildProcess.Options()
            options.output = .pipe
            guard let process = try? ChildProcess.spawn("/usr/bin/log", [
                "stream", "--style", "ndjson", "--predicate",
                #"senderImagePath ENDSWITH "/Sandbox" AND eventMessage BEGINSWITH "Sandbox: ""#,
            ], options: options) else { return }
            self.process = process
            streaming = false
            reader = Task {
                for await line in process.standardOutput.lines() {
                    markStreaming()
                    guard let message = Parser.message(fromLine: line) else { continue }
                    deliver(message)
                }
                readerEnded(process)
            }
        }

        private func stopReading() {
            process?.signal(SIGTERM)
            process = nil
            reader = nil
            streaming = false
        }

        private func deliver(_ message: Parser.Message) {
            for subscriber in subscribers.values {
                if let event = subscriber.parser.event(from: message) { subscriber.continuation.yield(event) }
            }
        }

        /// 日志进程意外结束：还有订阅者就重新开一个
        private func readerEnded(_ ended: ChildProcess) {
            guard process === ended else { return }
            process = nil
            reader = nil
            if !subscribers.isEmpty { startReading() }
        }
    }

    struct Parser: Sendable {
        let boxPrefix: String
        let processNames: Set<String>
        let installer: Bool
        let home: String
        let session: SessionPID

        /// 一行日志解析出的拒绝记录
        struct Message: Sendable {
            let process: String
            let pid: pid_t
            let operation: String
            let target: String
        }

        // "Sandbox: QuarkCloudDrive(15215) deny(1) file-write-create /Users/x/Library/LaunchAgents/a.plist"
        static func message(fromLine line: String) -> Message? {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let text = json["eventMessage"] as? String,
                  let match = text.wholeMatch(of: /Sandbox: (.+?)\((\d+)\) deny\(\d+\) (\S+)\s*(.*)/) else { return nil }
            return Message(process: String(match.1), pid: pid_t(match.2) ?? 0,
                           operation: String(match.3), target: String(match.4))
        }

        func event(from message: Message) -> BlockEvent? {
            let name = message.process, target = message.target
            // 安装器调用 hdiutil 挂载被挡（实际由它拉起的 diskimages-helper 报告，进程不在盒子里）。
            // 只算到安装器头上：其他沙盒里的 hdiutil 也可能被拒绝，算给每个盒子的话，普通应用会冒出
            // “挂载磁盘映像”，正在运行的安装器还会被误判为下载完成、被提前结束
            let mountByHelper = installer && (name == "hdiutil" || name.hasPrefix("diskimages"))
                && target.contains("DiskArbitration")
            guard mountByHelper || Self.belongs(Identity.of(message.pid), main: session.pid, boxPrefix: boxPrefix,
                                                loggedName: name, processNames: processNames) else { return nil }
            return categorize(operation: message.operation, target: target)
        }

        /// 判断归属要用的进程信息。取信息（读进程表、问守卫）和判断分开，判断是纯函数，便于测试
        struct Identity: Sendable {
            /// 可执行文件路径；nil 表示进程已经退出
            var path: String?
            var parent: pid_t?
            var group: pid_t?
            /// 负责进程。只记下、不作为依据（见 belongs）
            var responsible: pid_t?
            /// 守卫记下的归属：继承了盒子沙盒规则的成员所属的会话主进程（见 EscapeGuard.session(of:)）
            var guardSession: pid_t?

            static func of(_ pid: pid_t) -> Identity {
                let lineage = ProcessTable.lineage(of: pid)
                return Identity(path: ProcessTable.path(of: pid), parent: lineage?.parent, group: lineage?.group,
                                responsible: ProcessTable.responsiblePID(of: pid),
                                guardSession: EscapeGuard.shared.session(of: pid))
            }
        }

        /// 这条记录是不是本盒子的进程报告的。按进程身份认，名字只用来认已经退出的进程：
        /// 本机同时开着同名的 App（盒子里第二个微信账号、本机的微信）、名字很普通的辅助程序
        /// （Sparkle 的 Installer、Updater），按名字认会把别人的拦截算到盒子头上；
        /// 反过来，盒子里的 App 调用的系统工具（cp、launchctl、defaults）名字不在盒子里，按名字认不出来。
        ///
        /// 只认继承了盒子沙盒规则的进程：位于盒子里的、守卫记下的会话成员、在会话进程组里的、父进程是会话主进程的。
        /// 不看负责进程：系统代 App 启动的 XPC 服务（WebKit 的 WebContent、GPU、Networking）负责进程也是 App，
        /// 但它们由 launchd 启动、带的是自己的沙盒，报告的拒绝不是盒子的规则挡的
        /// （每个 WebContent 启动时都会被拒绝读取 /dev/dtracehelper，算进来就成了“读取私人数据”）
        static func belongs(_ identity: Identity, main: pid_t?, boxPrefix: String,
                            loggedName: String, processNames: Set<String>) -> Bool {
            if let main, identity.guardSession == main { return true } // 守卫第一次看到它时就确认过归属
            guard let path = identity.path else {
                // 已经退出：只能看名字
                return processNames.contains { ViolationMonitor.loggedName(loggedName, matches: $0) }
            }
            if path.hasPrefix(boxPrefix) { return true }
            guard let main else { return false }
            // 在会话的进程组里（主进程退出后留下的进程派生的也在），或者是会话主进程直接派生、离开了进程组的
            return identity.group == main || identity.parent == main
        }

        private func categorize(operation: String, target: String) -> BlockEvent? {
            if operation == "forbidden-sandbox-reinit" { return nil } // Chromium 系 App 自带沙盒的正常现象
            if operation.hasPrefix("file-write") {
                if target.contains("/Library/LaunchDaemons") || target.contains("/Library/PrivilegedHelperTools") {
                    return BlockEvent(kind: .backgroundService, target: target)
                }
                if target.contains("/Library/LaunchAgents") { return BlockEvent(kind: .autostart, target: target) }
                if target.hasPrefix("/Applications") || target.hasPrefix("/Library") || target.hasPrefix("/usr/local")
                    || target.hasPrefix("/opt") || target.hasPrefix("/System/Volumes/Data/Applications") {
                    return BlockEvent(kind: .systemInstall, target: target)
                }
                if target.hasPrefix(home) { return BlockEvent(kind: .personalFiles, target: target) }
                return BlockEvent(kind: .other, target: target)
            }
            if operation.hasPrefix("file-read") { return BlockEvent(kind: .privacyRead, target: target) }
            if operation == "mach-lookup" {
                if target.contains("usernot") || target.contains("UNCUserNotification") {
                    return BlockEvent(kind: .notification, target: L("通知中心", "Notification Center"))
                }
                if target.contains("DiskArbitration") || target.contains("diskarbitrationd") {
                    return BlockEvent(kind: .diskMount, target: L("安装器自己下载的安装包", "Installer package downloaded by the installer"))
                }
                // SMAppService 登录项 / 后台项注册
                if target.contains("smd") || target.contains("backgroundtaskmanagement") {
                    return BlockEvent(kind: .autostart, target: L("登录项与后台项", "Login items and background items"))
                }
                return nil
            }
            if operation.hasPrefix("appleevent") { return BlockEvent(kind: .appleEvent, target: target) }
            return nil
        }
    }
}
