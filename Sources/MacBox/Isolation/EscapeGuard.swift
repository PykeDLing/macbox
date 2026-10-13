import Foundation
import Synchronization

/// 运行时守卫：盒子里的程序只能在沙盒中运行。
///
/// 安装器挂载自己下载的 dmg 后经由系统（LaunchServices）启动 App、有人从程序坞直接点开盒子里的 App……
/// 这些进程不是 MacBox 的子进程，不受沙盒约束。守卫每 50ms 检查一次新进程：
/// 可执行文件位于盒子或盒子挂载的卷上的，必须同时满足
/// - 在沙盒中，并且
/// - 负责进程是 MacBox 登记过的运行会话（会话主进程以 disclaim 方式启动，它派生的进程都记在它头上），
/// 否则立即结束。只看“在不在沙盒中”不够：自带苹果沙盒的 App 从程序坞直接打开时也在沙盒中，
/// MacBox 崩溃后遗留的进程也在沙盒中，但它们都不受 MacBox 管理。
nonisolated final class EscapeGuard: Sendable {
    static let shared = EscapeGuard()

    /// 被结束的逃逸进程
    struct Escape: Sendable {
        /// 可执行文件路径
        let path: String
        /// 它属于哪个盒子：位于盒子里时是它自己的路径，位于卷上时是挂载这个卷的映像文件路径
        let owner: String
    }

    private struct State {
        var roots: [String] = []
        /// 由盒子里的映像挂载出来的卷：挂载点 → 映像文件路径
        var volumes: [String: String] = [:]
        /// 已检查过的进程；路径为 xpcproxy / sandbox-exec 的还会 exec 成别的程序，需要复查
        var seen: [pid_t: String] = [:]
        /// 正在运行的会话主进程
        var sessions: Set<pid_t> = []
        var ticks = 0
        var onEscape: (@MainActor @Sendable (Escape) -> Void)?
        var loop: Task<Void, Never>?
    }

    private let state = Mutex(State())

    /// 开始守卫；onEscape 在主线程回调
    func start(onEscape: @escaping @MainActor @Sendable (Escape) -> Void) {
        let roots = [FileOps.realPath(AppPaths.boxes) + "/"]
        state.withLock { state in
            guard state.loop == nil else { return }
            state.roots = roots
            state.onEscape = onEscape
            state.loop = Task.detached(priority: .userInitiated) { [self] in
                while !Task.isCancelled {
                    tick()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    /// 登记一个会话主进程：负责进程是它的程序都允许运行（在沙盒中的前提下）
    func register(session pid: pid_t) {
        state.withLock { _ = $0.sessions.insert(pid) }
    }

    func unregister(session pid: pid_t) {
        state.withLock { _ = $0.sessions.remove(pid) }
    }

    /// 重新读取由盒子里的映像挂载出来的卷；列表变化时所有进程重新检查一遍
    @concurrent
    static func refreshVolumes() async {
        var volumes: [String: String] = [:]
        for image in await DiskImage.attached(fromImagesUnder: FileOps.realPath(AppPaths.boxes)) {
            let owner = FileOps.realPath(URL(fileURLWithPath: image.imagePath))
            for mountPoint in image.mountPoints {
                volumes[mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"] = owner
            }
        }
        let changed = shared.state.withLock { state in
            guard volumes != state.volumes else { return false }
            state.volumes = volumes
            state.seen.removeAll()
            return true
        }
        if changed { shared.tick() }
    }

    private func tick() {
        let pids = ProcessTable.allPIDs()
        let (escapes, handler) = state.withLock { state -> ([Escape], (@MainActor @Sendable (Escape) -> Void)?) in
            state.ticks += 1
            if state.ticks % 200 == 0 { // 每 10 秒清理已退出的进程
                let alive = Set(pids)
                state.seen = state.seen.filter { alive.contains($0.key) }
            }
            var escapes: [Escape] = []
            for pid in pids {
                if let previous = state.seen[pid], !Self.transient(previous) { continue }
                guard let path = ProcessTable.path(of: pid) else { continue }
                state.seen[pid] = path
                guard let owner = owner(of: path, in: state), !Self.isManaged(pid, sessions: state.sessions) else { continue }
                kill(pid, SIGKILL)
                state.seen[pid] = nil
                escapes.append(Escape(path: path, owner: owner))
            }
            return (escapes, state.onEscape)
        }
        guard let handler, !escapes.isEmpty else { return }
        Task { @MainActor in
            for escape in escapes { handler(escape) }
        }
    }

    private func owner(of path: String, in state: State) -> String? {
        if state.roots.contains(where: { path.hasPrefix($0) }) { return path }
        return state.volumes.first { path.hasPrefix($0.key) }?.value
    }

    static func isManaged(_ pid: pid_t, sessions: Set<pid_t>) -> Bool {
        guard ProcessTable.isSandboxed(pid) else { return false }
        // 查不到负责进程（接口不可用）时退回只看沙盒
        guard let responsible = ProcessTable.responsiblePID(of: pid) else { return true }
        return sessions.contains(responsible)
    }

    private static func transient(_ path: String) -> Bool {
        path.hasSuffix("/xpcproxy") || path.hasSuffix("/sandbox-exec") || path.isEmpty
    }
}
