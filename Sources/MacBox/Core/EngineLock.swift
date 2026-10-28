import Darwin
import Foundation
import Synchronization

/// 引擎锁：同一个数据目录，同一时间只能由一个 MacBox 进程管理。
///
/// 运行中的会话、借出的偏好设置、盒子正在做什么，都只记在管理盒子的那个进程里。第二个进程不知道这些：
/// 启动时的收尾会把正在运行的应用当成上次异常退出留下的——结束它们、收回它们借出的设置、给它们的 App 上锁
/// （见 BoxStore.recoverInterruptedSessions），它的守卫也会把它们当成逃逸进程结束。
///
/// 做法是用 flock 锁住数据目录里的 engine.lock，一直持有到进程结束：进程退出时（包括崩溃、被强制结束）
/// 内核自动释放，不会留下过期的锁。文件里写着谁拿着锁，只用来告诉用户是哪个 MacBox；归属只看 flock
nonisolated final class EngineLock: Sendable {
    /// 拿着锁的进程
    struct Holder: Codable, Equatable, Sendable {
        let pid: pid_t
        /// 它的 App 包（不是 App 时是可执行文件）
        let path: String
        let version: String?

        static var current: Holder {
            Holder(pid: getpid(), path: Bundle.main.bundlePath,
                   version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        }

        /// 它是 App 时，App 包的位置
        var appURL: URL? { path.hasSuffix(".app") ? URL(fileURLWithPath: path, isDirectory: true) : nil }
    }

    enum Outcome: Sendable {
        case acquired(EngineLock)
        /// 另一个进程拿着。读不出是谁时为 nil（它刚拿到、还没写完，或者不是 MacBox 锁的）
        case heldByOther(Holder?)
    }

    static let fileName = "engine.lock"

    let url: URL
    /// 一直开着、锁着，进程结束时由内核关闭、释放
    let descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    /// 这个进程已经拿到的锁（按锁文件的路径）
    private static let held = Mutex<[String: EngineLock]>([:])

    /// 拿 directory 里的引擎锁。这个进程已经拿到过时返回同一把：flock 按打开的文件算，同一个进程再打开、
    /// 再锁一次也会被自己挡住（测试在一个进程里先后建好几个 BoxStore）。锁文件建不了、打不开时抛出错误
    static func acquire(in directory: URL, as holder: Holder = .current) throws -> Outcome {
        let url = directory.appending(path: fileName)
        return try held.withLock { held throws -> Outcome in
            if let lock = held[url.path] { return .acquired(lock) }
            try AppPaths.ensure(directory)
            // O_CLOEXEC：盒子里的程序继承了它的话，MacBox 崩溃后锁还被它们占着，下次就启动不了了。
            // O_NOFOLLOW：数据目录里的东西不顺着链接走
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw posixError() }
            var result: Int32
            repeat { result = flock(descriptor, LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
            guard result == 0 else {
                let error = posixError()
                defer { close(descriptor) }
                guard error.code == .EWOULDBLOCK else { throw error }
                return .heldByOther(readHolder(descriptor))
            }
            write(holder, to: descriptor)
            let lock = EngineLock(url: url, descriptor: descriptor)
            held[url.path] = lock
            return .acquired(lock)
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func readHolder(_ descriptor: Int32) -> Holder? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: Data(buffer.prefix(count)))
    }

    /// 写不进去也不要紧：只是认不出是谁拿着
    private static func write(_ holder: Holder, to descriptor: Int32) {
        guard let data = try? JSONEncoder().encode(holder) else { return }
        _ = ftruncate(descriptor, 0)
        _ = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }
}
