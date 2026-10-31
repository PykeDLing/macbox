import Darwin
import Dispatch
import Foundation
import Synchronization

/// MacBox 启动子进程的唯一入口（命令行工具、系统日志、隔离中的 App 都经由它）。
///
/// - 子进程只拿到明确交给它的 0/1/2 三个描述符（POSIX_SPAWN_CLOEXEC_DEFAULT），
///   不会继承 MacBox 打开的其他文件和管道。
/// - 输出用 DispatchIO 在调度队列上读取，不在 Swift 并发线程池里做阻塞读：
///   一个长期等待输出的读取（比如 log stream）不会拖住其他任何读取。
/// - 退出由 kqueue（DispatchSource 进程源）通知并立即回收，不为每个子进程占一个线程。
nonisolated final class ChildProcess: Sendable {
    enum Input: Sendable {
        case null
        case data(Data)
    }

    enum Output: Sendable {
        case null
        /// 通过 `standardOutput` / `standardError` 读取
        case pipe
    }

    struct Options: Sendable {
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var input: Input = .null
        var output: Output = .null
        var error: Output = .null
        /// 放进以自己为首的新进程组，便于整组结束
        var newProcessGroup = false
        /// 让新进程自己承担系统权限（摄像头、麦克风等）的归属，而不是记到 MacBox 头上
        var disclaimResponsibility = false
    }

    let pid: pid_t
    let processGroup: pid_t?
    /// 标准输出的数据块；进程关闭输出（通常是退出）时结束。未请求管道时为空序列
    let standardOutput: AsyncStream<Data>
    let standardError: AsyncStream<Data>

    private struct ExitState {
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let exitState = Mutex(ExitState())
    /// 已经回收（waitpid 成功）
    private let reaped = Mutex(false)
    /// 进程源要一直持有到进程退出
    private let source = Mutex<DispatchSourceProcess?>(nil)
    private static let queue = DispatchQueue(label: "MacBox.ChildProcess", attributes: .concurrent)

    private init(pid: pid_t, processGroup: pid_t?, standardOutput: AsyncStream<Data>, standardError: AsyncStream<Data>) {
        self.pid = pid
        self.processGroup = processGroup
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    // MARK: - 启动

    static func spawn(_ executable: String, _ arguments: [String], options: Options = Options()) throws -> ChildProcess {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        if options.newProcessGroup {
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        if options.disclaimResponsibility, let disclaim = Private.disclaim { _ = disclaim(&attributes, 1) }

        // 子进程一端在 spawn 后关闭，父进程一端交给读写方
        var childEnds: [Int32] = []
        defer { childEnds.forEach { close($0) } }
        var parentEnds: [Int32] = []

        var stdinWriter: Int32?
        switch options.input {
        case .null:
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        case .data:
            let (read, write) = try makePipe()
            childEnds.append(read); parentEnds.append(write)
            posix_spawn_file_actions_adddup2(&actions, read, 0)
            stdinWriter = write
        }

        func route(_ output: Output, to fd: Int32) throws -> Int32? {
            switch output {
            case .null:
                posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_WRONLY, 0)
                return nil
            case .pipe:
                let (read, write) = try makePipe()
                childEnds.append(write); parentEnds.append(read)
                posix_spawn_file_actions_adddup2(&actions, write, fd)
                return read
            }
        }
        let stdoutReader: Int32?, stderrReader: Int32?
        do {
            stdoutReader = try route(options.output, to: 1)
            stderrReader = try route(options.error, to: 2)
        } catch {
            parentEnds.forEach { close($0) }
            throw error
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = options.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            parentEnds.forEach { close($0) }
            let tool = (executable as NSString).lastPathComponent, reason = String(cString: strerror(status))
            throw MacBoxError(String(localized: "无法启动 \(tool)：\(reason)"))
        }

        let process = ChildProcess(pid: pid, processGroup: options.newProcessGroup ? pid : nil,
                                   standardOutput: stdoutReader.map(stream(reading:)) ?? emptyStream(),
                                   standardError: stderrReader.map(stream(reading:)) ?? emptyStream())
        if let stdinWriter, case .data(let data) = options.input { write(data, to: stdinWriter) }
        process.watchExit()
        return process
    }

    // MARK: - 退出

    /// 等待进程退出，返回退出码（被信号结束时为 128 + 信号）。可多次、并发调用
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = exitState.withLock { state -> Int32? in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    var hasExited: Bool { exitState.withLock { $0.status != nil } }

    /// 发信号；建了进程组时发给整组。
    /// 组长（这个进程）退出后组里可能还有它派生的进程，仍然发给整组：组里还有进程时，
    /// 内核不会把这个号码分给新进程，所以不会误伤。只有号码已被新进程占用（说明整组早已结束）时才不发
    func signal(_ signal: Int32) {
        if let processGroup {
            if hasExited, kill(processGroup, 0) == 0 || errno != ESRCH { return }
            killpg(processGroup, signal)
        } else if !hasExited {
            kill(pid, signal)
        }
    }

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: Self.queue)
        // 内核在进程变成僵尸之前就发出 NOTE_EXIT（proc_exit 先通知、后置 SZOMB），
        // 这时 WNOHANG 的 waitpid 可能返回 0，而退出事件只有一次，进程就永远没人回收、等待方永远等不到。
        // 收到退出事件说明进程正在退出，阻塞等待只需几微秒（在并发队列上，不影响其他读取）
        source.setEventHandler { [self] in reap(blocking: true) }
        self.source.withLock { $0 = source }
        source.activate()
        // 进程在挂上进程源之前就已退出时不会有事件，补查一次
        reap(blocking: false)
    }

    /// 回收僵尸进程并唤醒等待方；只有第一次成功的 waitpid 会生效。
    /// 两处回收（补查和退出事件）由锁串行：阻塞的那次必须知道对方是否已经回收，否则可能等到同号的其他进程
    private func reap(blocking: Bool) {
        let raw = reaped.withLock { reaped -> Int32? in
            guard !reaped else { return nil }
            var raw: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &raw, blocking ? 0 : WNOHANG) } while result == -1 && errno == EINTR
            guard result == pid else { return nil }
            reaped = true
            return raw
        }
        guard let raw else { return }
        let status = Self.exitCode(raw)
        let waiters = exitState.withLock { state -> [CheckedContinuation<Int32, Never>] in
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        source.withLock { source in
            source?.cancel()
            source = nil
        }
        waiters.forEach { $0.resume(returning: status) }
    }

    private static func exitCode(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }

    // MARK: - 管道

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            let reason = String(cString: strerror(errno))
            throw MacBoxError(String(localized: "无法创建管道：\(reason)"))
        }
        // 父进程这边的描述符不能被其他途径启动的进程继承
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// 在调度队列上读，读到的数据块依次送进序列；读完关闭描述符
    private static func stream(reading fd: Int32) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty {
                var chunk = Data(capacity: data.count)
                data.enumerateBytes { bytes, _, _ in chunk.append(bytes) }
                continuation.yield(chunk)
            }
            if done {
                continuation.finish()
                channel.close()
            }
        }
        continuation.onTermination = { _ in channel.close(flags: .stop) }
        return stream
    }

    private static func write(_ data: Data, to fd: Int32) {
        // 对方提前退出时写入返回 EPIPE，而不是用 SIGPIPE 结束 MacBox
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in close(fd) }
        let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: payload, queue: queue) { done, _, _ in
            if done { channel.close() }
        }
    }

    private static func emptyStream() -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }
}

nonisolated extension AsyncSequence where Element == Data, Self: Sendable {
    /// 按行切分（不含换行符）；最后一行没有换行也会给出
    func lines() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let task = Task {
            var buffer = Data()
            do {
                for try await chunk in self {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        continuation.yield(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
            } catch {}
            if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// 读完全部数据
    func collect() async -> Data {
        var data = Data()
        do { for try await chunk in self { data.append(chunk) } } catch {}
        return data
    }
}

/// libsystem 里未公开但长期稳定的接口
nonisolated enum Private {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    static let disclaim: Disclaim? = symbol("responsibility_spawnattrs_setdisclaim")

    /// 进程的“负责进程”：disclaim 启动的 App 对自己负责，它派生的进程都记在它头上
    typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    static let responsiblePID: ResponsiblePID? = symbol("responsibility_get_pid_responsible_for_pid")

    /// sandbox_check(pid, NULL, 0)：进程是否处于沙盒中
    typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
    static let sandboxCheck: SandboxCheck? = symbol("sandbox_check")

    private static func symbol<T>(_ name: String) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }
}
