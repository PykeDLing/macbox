import Foundation
import Synchronization

/// 被拦截的一次行为（来自系统日志里的沙盒拒绝记录）。存进运行报告（见 RunReport），字段只增不改
nonisolated struct BlockEvent: Identifiable, Hashable, Codable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case autostart, backgroundService, systemInstall, escapedLaunch, diskMount, personalFiles, privacyRead, notification, appleEvent
        /// 不许联网时的连接、域名解析（见 SandboxProfile.offlineRules）
        case network
        case other

        var title: String {
            switch self {
            case .escapedLaunch: String(localized: "在沙盒外启动程序")
            case .diskMount: String(localized: "挂载磁盘映像")
            case .autostart: String(localized: "注册开机自启动")
            case .backgroundService: String(localized: "注册后台服务")
            case .systemInstall: String(localized: "写入系统目录")
            case .personalFiles: String(localized: "写入你的个人文件夹")
            case .privacyRead: String(localized: "读取私人数据")
            case .notification: String(localized: "发送通知")
            case .appleEvent: String(localized: "控制其他 App")
            case .network: String(localized: "联网")
            case .other: String(localized: "其他系统操作")
            }
        }

        /// 这类行为被挡住后，软件的功能可能不完整，建议改用虚拟 Mac
        /// 开机自启被挡只是“不再自启”，不影响使用，所以不算
        var suggestsVirtualMac: Bool { [.backgroundService, .systemInstall].contains(self) }
    }

    /// 不是路径、地址的拦截对象。target 里存它的代码（见 code），显示时才按当前语言生成文字
    nonisolated enum Subject: Hashable, Sendable {
        case notificationCenter
        case nameLookup
        case backgroundDownloads
        /// 在线安装器自己下载的安装包（挂载它被挡）
        case installerPackage
        /// 登录项与后台项（SMAppService）
        case loginItems
        /// 连接服务器的某个端口，nil 是任意端口
        case connect(port: Int?)
        /// 在某个端口等待别的设备连进来，nil 是任意端口
        case listen(port: Int?)
        /// 系统的 ssh-agent（里面是你的 SSH 钥匙）
        case sshAgent

        var code: String {
            switch self {
            case .notificationCenter: "notification-center"
            case .nameLookup: "dns"
            case .backgroundDownloads: "background-downloads"
            case .installerPackage: "installer-package"
            case .loginItems: "login-items"
            case .sshAgent: "ssh-agent"
            case .connect(let port): "connect:\(port.map(String.init) ?? "*")"
            case .listen(let port): "listen:\(port.map(String.init) ?? "*")"
            }
        }

        init?(code: String) {
            switch code {
            case "notification-center": self = .notificationCenter
            case "dns": self = .nameLookup
            case "background-downloads": self = .backgroundDownloads
            case "installer-package": self = .installerPackage
            case "login-items": self = .loginItems
            case "ssh-agent": self = .sshAgent
            default:
                guard let match = code.wholeMatch(of: /(connect|listen):(\*|\d+)/) else { return nil }
                let port = Int(match.2)
                self = match.1 == "connect" ? .connect(port: port) : .listen(port: port)
            }
        }

        var text: String {
            switch self {
            case .notificationCenter: String(localized: "通知中心")
            case .nameLookup: String(localized: "域名解析（DNS）")
            case .backgroundDownloads: String(localized: "后台下载服务")
            case .installerPackage: String(localized: "安装器自己下载的安装包")
            case .loginItems: String(localized: "登录项与后台项")
            case .sshAgent: String(localized: "SSH 代理（ssh-agent）里你的钥匙")
            case .connect(nil): String(localized: "block.subject.connect", defaultValue: "连接服务器", comment: "被挡住的动作：连接任意端口的服务器")
            // 端口是编号，按字符串插进去：整数插值会按本地习惯加千位分隔符（8,080）
            case .connect(let port?): String(localized: "连接服务器的 \(String(port)) 端口")
            case .listen(nil): String(localized: "等待别的设备连进来")
            case .listen(let port?): String(localized: "在 \(String(port)) 端口等待别的设备连进来")
            }
        }

        /// 0.4.0 的报告里存的是记录时那种语言的文字，对照回来。不要改这些文字，改措辞请改 text
        init?(legacyText text: String) {
            switch text {
            case "通知中心", "Notification Center": self = .notificationCenter
            case "域名解析（DNS）", "Name lookups (DNS)": self = .nameLookup
            case "后台下载服务", "Background download service": self = .backgroundDownloads
            case "安装器自己下载的安装包", "Installer package downloaded by the installer": self = .installerPackage
            case "登录项与后台项", "Login items and background items": self = .loginItems
            case "连接服务器", "Connect to a server": self = .connect(port: nil)
            case "等待别的设备连进来", "Wait for other devices to connect": self = .listen(port: nil)
            default:
                if let match = text.wholeMatch(of: /连接服务器的 (\d+) 端口/) ?? text.wholeMatch(of: /Connect to a server on port (\d+)/) {
                    self = .connect(port: Int(match.1))
                } else if let match = text.wholeMatch(of: /在 (\d+) 端口等待别的设备连进来/)
                            ?? text.wholeMatch(of: /Wait for other devices to connect on port (\d+)/) {
                    self = .listen(port: Int(match.1))
                } else {
                    return nil
                }
            }
        }
    }

    let kind: Kind
    /// 被挡住的对象：路径（报告里的见 PathTidier）、地址（203.0.113.9:80）、App 的标识符原样，其余是 Subject 的代码。
    /// 不随界面语言变化，显示用 targetText
    let target: String
    var count = 1
    var lastSeen = Date()
    /// 路径的 id 存进了 BoxConfig.acknowledgedBlocks，不能变
    var id: String { "\(kind.rawValue)|\(target)" }

    var subject: Subject? { Subject(code: target) }
    /// 显示的对象：代码按当前语言生成文字，路径、地址原样
    var targetText: String { subject?.text ?? target }
}

nonisolated extension BlockEvent {
    init(kind: Kind, subject: Subject) {
        self.init(kind: kind, target: subject.code)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 以后的版本加的类型认不出时算“其他”，不让整份报告读不出（0.4.1 及以前读到新类型会）。同 FileArea.Location
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .other
        let target = try container.decode(String.self, forKey: .target)
        self.target = Subject(legacyText: target)?.code ?? target
        count = try container.decode(Int.self, forKey: .count)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
    }
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

/// 系统日志里的沙盒记录：拒绝记录，以及规则要求放行时也记一笔的启动程序、写「下载」和你选的文件夹（见 SandboxProfile）。
///
/// 记录有两个来源：命令行程序这类的由内核直接写进日志；带 App 包的进程（应用本身、它的辅助程序）由 sandboxd
/// 生成一份完整的违规报告（第一行是同样格式的记录，后面是进程信息和调用栈）。实测同一条不会两边都报。
/// 只看内核的话，带界面的应用发通知、启动程序这些都看不到。
///
/// 整个 MacBox 只开一个 `log stream`：第一个订阅者到来时启动，最后一个离开时结束，
/// 每行日志只解析一次，再按盒子分发。同时运行多个应用时不会有多份日志进程各自解析全部日志。
///
/// 这是**尽力而为**的信号：内核对沙盒拒绝报告做全局限流（其他进程大量报告时，盒子里的报告会被丢弃），
/// 所以“没有记录”不代表“没有被拦截”。只能用于提示，不能作为安全或流程判断的唯一依据。
nonisolated enum ViolationMonitor {
    /// 本盒子进程的拦截记录和启动的程序；停止迭代（任务取消）时退订。
    /// 返回前等日志流真正开始输出（最多 3 秒），App 启动时的拦截不会因为日志进程还没就绪而漏掉
    /// - processNames：盒子里各个可执行文件的名字，只用来认已经退出的进程
    /// - installer：盒子里是在线安装器（它的规则禁止挂载磁盘映像，见 SandboxProfile）
    /// - session：会话主进程。订阅要在启动 App 之前，所以先给一个空的，启动后再填上
    static func events(boxPrefix: String, processNames: Set<String>, installer: Bool = false,
                       session: SessionPID) async -> AsyncStream<RunActivity> {
        let (stream, continuation) = AsyncStream.makeStream(of: RunActivity.self)
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
        private var subscribers: [UUID: (parser: Parser, continuation: AsyncStream<RunActivity>.Continuation)] = [:]
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

        func subscribe(_ id: UUID, parser: Parser, continuation: AsyncStream<RunActivity>.Continuation) {
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
                #"(senderImagePath ENDSWITH "/Sandbox" OR (subsystem == "com.apple.sandbox.reporting" AND category == "violation")) AND eventMessage BEGINSWITH "Sandbox: ""#,
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
                if let activity = subscriber.parser.activity(from: message) { subscriber.continuation.yield(activity) }
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

        /// 一行日志解析出的记录
        struct Message: Sendable {
            let process: String
            let pid: pid_t
            let operation: String
            let target: String
            /// 规则放行、只是要求记一笔的（见 SandboxProfile 里带 report 的规则），不是拒绝
            var allowed = false
        }

        // "Sandbox: QuarkCloudDrive(15215) deny(1) file-write-create /Users/x/Library/LaunchAgents/a.plist"
        // "Sandbox: bash(30453) allow process-exec* /usr/sbin/ioreg"
        // sandboxd 的报告只看第一行，后面是进程信息和调用栈
        static func message(fromLine line: String) -> Message? {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let report = json["eventMessage"] as? String,
                  let text = report.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
                  let match = text.wholeMatch(of: /Sandbox: (.+?)\((\d+)\) (deny|allow)(?:\(\d+\))? (\S+)\s*(.*)/) else { return nil }
            return Message(process: String(match.1), pid: pid_t(match.2) ?? 0,
                           operation: String(match.4), target: String(match.5), allowed: match.3 == "allow")
        }

        /// 这条记录对本盒子意味着什么：被挡住的行为、启动了程序、在盒子外放行的地方写了东西；不是本盒子的、不关心的为 nil
        func activity(from message: Message) -> RunActivity? {
            guard message.allowed else { return event(from: message).map(RunActivity.blocked) }
            // 带 report 的规则只有启动程序、写「下载」和你选的文件夹。启动程序记下的是启动后的程序，进程名是启动它的那个（exec 前的名字）
            let launch = message.operation.hasPrefix("process-exec"), write = message.operation.hasPrefix("file-write")
            guard launch || write, message.target.hasPrefix("/"),
                  Self.belongs(Identity.of(message.pid), main: session.pid, boxPrefix: boxPrefix,
                               loggedName: message.process, processNames: processNames) else { return nil }
            return launch ? .launched(message.target) : .wroteShared(path: message.target, operation: message.operation)
        }

        /// 拒绝记录对应的拦截；放行的记录、不是本盒子的为 nil
        func event(from message: Message) -> BlockEvent? {
            guard !message.allowed else { return nil }
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

        /// 拒绝记录是哪一类拦截（不看归属）；不关心的为 nil
        func categorize(operation: String, target: String) -> BlockEvent? {
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
            if operation.hasPrefix("network") { return Self.networkEvent(operation: operation, target: target, home: home) }
            if operation == "mach-lookup" {
                if target.contains("usernot") || target.contains("UNCUserNotification") {
                    return BlockEvent(kind: .notification, subject: .notificationCenter)
                }
                if target == "com.apple.dnssd.service" {
                    return BlockEvent(kind: .network, subject: .nameLookup)
                }
                if target.hasPrefix("com.apple.nsurlsessiond") {
                    return BlockEvent(kind: .network, subject: .backgroundDownloads)
                }
                if target.contains("DiskArbitration") || target.contains("diskarbitrationd") {
                    return BlockEvent(kind: .diskMount, subject: .installerPackage)
                }
                // SMAppService 登录项 / 后台项注册
                if target.contains("smd") || target.contains("backgroundtaskmanagement") {
                    return BlockEvent(kind: .autostart, subject: .loginItems)
                }
                return nil
            }
            if operation.hasPrefix("appleevent") { return BlockEvent(kind: .appleEvent, target: target) }
            return nil
        }

        /// 不许联网时被挡住的连接（见 SandboxProfile.offlineRules）。日志里看不到对方的地址，只有端口：
        /// “network-outbound remote:*:443”；等别人连进来是 “network-inbound local:*:8080”（bind 也报这个）；
        /// 域名解析是连 mDNSResponder 的套接字。
        /// 本地套接字记的是真实路径：联不联网都挡的 ssh-agent、你主目录（home，真实路径）里别的程序的套接字
        /// （见 SandboxProfile），算作读取私人数据：连上就能借用你的钥匙和凭证。其他本地套接字规则没挡，不是盒子的规则报告的
        static func networkEvent(operation: String, target: String, home: String) -> BlockEvent? {
            if target == "/private/var/run/mDNSResponder" {
                return BlockEvent(kind: .network, subject: .nameLookup)
            }
            if target.hasPrefix("/") {
                guard operation == "network-outbound" else { return nil }
                // 先按结尾筛，免得每条都编译一次（Regex 不能放进静态常量：不是 Sendable）
                if target.hasSuffix("/Listeners"), let agent = try? Regex(SandboxProfile.sshAgentSocket), target.wholeMatch(of: agent) != nil {
                    return BlockEvent(kind: .privacyRead, subject: .sshAgent)
                }
                return target.hasPrefix(home + "/") ? BlockEvent(kind: .privacyRead, target: target) : nil
            }
            let outbound = operation == "network-outbound"
            guard let address = target.wholeMatch(of: outbound ? /remote:(.+)/ : /local:(.+)/)?.1,
                  let separator = address.lastIndex(of: ":") else { return nil }
            let host = address[..<separator], port = Int(address[address.index(after: separator)...]) // "*"（任意端口）为 nil
            if !outbound { return BlockEvent(kind: .network, subject: .listen(port: port)) }
            if host != "*" { return BlockEvent(kind: .network, target: String(address)) }
            return BlockEvent(kind: .network, subject: .connect(port: port))
        }
    }
}
