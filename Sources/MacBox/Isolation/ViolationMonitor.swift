import Foundation

/// 被拦截的一次行为（来自系统日志里的沙盒拒绝记录）
nonisolated struct BlockEvent: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case autostart, backgroundService, systemInstall, escapedLaunch, diskMount, personalFiles, privacyRead, notification, appleEvent, other

        var title: String {
            switch self {
            case .escapedLaunch: "在沙盒外启动程序"
            case .diskMount: "挂载磁盘映像"
            case .autostart: "注册开机自启动"
            case .backgroundService: "注册后台服务"
            case .systemInstall: "写入系统目录"
            case .personalFiles: "写入你的个人文件夹"
            case .privacyRead: "读取私人数据"
            case .notification: "发送通知"
            case .appleEvent: "控制其他 App"
            case .other: "其他系统操作"
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
    static func events(boxPrefix: String, processNames: Set<String>) async -> AsyncStream<BlockEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: BlockEvent.self)
        let parser = Parser(boxPrefix: boxPrefix, processNames: processNames, home: FileOps.realPath(AppPaths.realHome))
        let id = UUID()
        continuation.onTermination = { _ in Task { await hub.unsubscribe(id) } }
        await hub.subscribe(id, parser: parser, continuation: continuation)
        await hub.waitUntilStreaming(timeout: .seconds(3))
        return stream
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

    private struct Parser: Sendable {
        let boxPrefix: String
        let processNames: Set<String>
        let home: String

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
            // 安装器调用 hdiutil 挂载被挡（实际由它拉起的 diskimages-helper 报告）：只有盒子的规则会拒绝 DiskArbitration
            let mountByHelper = (name == "hdiutil" || name.hasPrefix("diskimages")) && target.contains("DiskArbitration")
            let belongs = processNames.contains { name.hasPrefix($0) }
                || ProcessTable.path(of: message.pid)?.hasPrefix(boxPrefix) == true || mountByHelper
            guard belongs else { return nil }
            return categorize(operation: message.operation, target: target)
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
                    return BlockEvent(kind: .notification, target: "通知中心")
                }
                if target.contains("DiskArbitration") || target.contains("diskarbitrationd") {
                    return BlockEvent(kind: .diskMount, target: "安装器自己下载的安装包")
                }
                // SMAppService 登录项 / 后台项注册
                if target.contains("smd") || target.contains("backgroundtaskmanagement") {
                    return BlockEvent(kind: .autostart, target: "登录项与后台项")
                }
                return nil
            }
            if operation.hasPrefix("appleevent") { return BlockEvent(kind: .appleEvent, target: target) }
            return nil
        }
    }
}
