import Foundation
import Synchronization

/// 运行时守卫：盒子里的程序只能在沙盒中运行。
///
/// 安装器挂载自己下载的 dmg 后经由系统（LaunchServices）启动 App、有人从程序坞直接点开盒子里的 App……
/// 这些进程不是 MacBox 的子进程，不受沙盒约束。守卫每 50ms 检查一次新进程：
/// 可执行文件（或者解释器运行的脚本）位于盒子或盒子挂载的卷上的，必须同时满足
/// - 在沙盒中，并且
/// - 属于 MacBox 登记过的运行会话，
/// 否则立即结束。只看“在不在沙盒中”不够：自带苹果沙盒的 App 从程序坞直接打开时也在沙盒中，
/// MacBox 崩溃后遗留的进程也在沙盒中，但它们都不受 MacBox 管理。
///
/// 进程属于哪个会话，在第一次看到它时确定并记下来（见 relatedSession），之后不再重新推导：
/// 会话主进程退出后，留下的进程改为对自己负责、父进程变成 launchd，再推导就认不出来了，
/// 而启动器式的主程序、“重启以生效”的辅助进程正是在主进程退出后才派生新进程
nonisolated final class EscapeGuard: Sendable {
    static let shared = EscapeGuard()

    /// 被结束的逃逸进程
    struct Escape: Sendable {
        /// 可执行文件路径（解释器运行的脚本是脚本的路径）
        let path: String
        /// 它属于哪个盒子：位于盒子里时是它自己的路径，位于卷上时是挂载这个卷的映像文件路径
        let owner: String
    }

    /// 会话里的一个进程
    private struct Member {
        /// 所属会话的主进程
        let session: pid_t
        /// 上次清理时已经不在了：再保留一轮（约 10 秒），拦截记录晚到时还能认出它（见 ViolationMonitor）
        var exited = false
    }

    private struct State {
        var roots: [String] = []
        /// 由盒子里的映像挂载出来的卷：挂载点 → 映像文件路径
        var volumes: [String: String] = [:]
        /// 已检查过的进程和当时的可执行文件路径。路径为 xpcproxy / sandbox-exec 的还会 exec 成别的程序，每次都复查；
        /// 其余的每半秒复查一次（先 exec 成系统程序、再 exec 成盒子里的程序的，第一次看到时还不在盒子里）
        var seen: [pid_t: String] = [:]
        /// 正在运行的会话主进程（也是会话的进程组号）
        var sessions: Set<pid_t> = []
        /// 会话里的进程（含会话主进程）→ 归属
        var members: [pid_t: Member] = [:]
        /// 上次 MacBox 运行时遗留下来的盒子进程：照样结束，但不当作逃逸回调（不记录、不在隔离中重新打开）
        var preexisting: Set<pid_t> = []
        var ticks = 0
        var onEscape: (@MainActor @Sendable (Escape) -> Void)?
        var loop: Task<Void, Never>?
    }

    private let state = Mutex(State())
    /// 守卫的目录，nil 时是 AppPaths.boxes（测试时换成别处，不碰真实的盒子）
    private let boxesOverride: URL?

    init(boxes: URL? = nil) {
        boxesOverride = boxes
    }

    /// 开始守卫；onEscape 在主线程回调。
    /// - preexisting：开始前就在运行的盒子进程（见 boxProcessesNow），静默结束
    func start(preexisting: Set<pid_t> = [], onEscape: @escaping @MainActor @Sendable (Escape) -> Void) {
        let roots = [FileOps.realPath(boxesOverride ?? AppPaths.boxes) + "/"]
        state.withLock { state in
            guard state.loop == nil else { return }
            state.roots = roots
            state.preexisting = preexisting
            state.onEscape = onEscape
            state.loop = Task.detached(priority: .userInitiated) { [self] in
                while !Task.isCancelled {
                    tick()
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
    }

    /// 停止守卫（测试用）
    func stop() {
        state.withLock { state in
            state.loop?.cancel()
            state.loop = nil
        }
    }

    /// 此刻可执行文件（或运行的脚本）位于盒子里的进程。MacBox 启动时、开始守卫之前调用：
    /// 这时还没有任何会话，它们都是上次运行遗留的
    static func boxProcessesNow() -> Set<pid_t> {
        let roots = [FileOps.realPath(AppPaths.boxes) + "/"]
        return Set(ProcessTable.allPIDs().filter { pid in
            guard let path = ProcessTable.path(of: pid) else { return false }
            return boxProcess(pid, path: path, roots: roots, volumes: [:]) != nil
        })
    }

    /// 登记一个会话主进程（启动后立即调用）：它和它派生的、在沙盒中的程序都允许运行
    func register(session pid: pid_t) {
        state.withLock { state in
            state.sessions.insert(pid)
            state.members[pid] = Member(session: pid)
        }
    }

    /// 会话结束（它的进程都已退出）：它的进程不再受管理。万一还有盒子里的程序在运行，下次检查时按逃逸结束
    func unregister(session pid: pid_t) {
        state.withLock { state in
            state.sessions.remove(pid)
            for (member, info) in state.members where info.session == pid {
                state.members[member] = nil
                state.seen[member] = nil
            }
        }
    }

    /// 进程属于哪个会话（含最近约 10 秒内退出的）。守卫没在运行、或者守卫没见过这个进程时为 nil
    func session(of pid: pid_t) -> pid_t? {
        state.withLock { $0.members[pid]?.session }
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

    /// 所有进程重新检查一遍（卷变化时；测试用）。已确认属于会话的进程保持原来的归属
    func recheckAll() {
        state.withLock { $0.seen.removeAll() }
        tick()
    }

    private func tick() {
        let pids = ProcessTable.allPIDs()
        let (escapes, handler) = state.withLock { state -> ([Escape], (@MainActor @Sendable (Escape) -> Void)?) in
            state.ticks += 1
            if state.ticks % 200 == 0 { Self.prune(&state, alive: Set(pids)) } // 每 10 秒清理已退出的进程
            let recheck = state.ticks % 10 == 0 // 每半秒复查一次路径（整张进程表约 1ms）
            var escapes: [Escape] = []
            for pid in pids {
                let previous = state.seen[pid]
                if let previous, !Self.transient(previous), !recheck { continue }
                guard let path = ProcessTable.path(of: pid) else { continue }
                if let previous, previous == path, !Self.transient(path) { continue }
                state.seen[pid] = path
                if !state.sessions.isEmpty, state.members[pid] == nil, let session = Self.relatedSession(pid, in: state) {
                    state.members[pid] = Member(session: session)
                }
                guard let escape = Self.boxProcess(pid, path: path, roots: state.roots, volumes: state.volumes) else { continue }
                // 负责进程接口不可用时退回只看沙盒（不误杀）
                let belongs = state.members[pid] != nil || Private.responsiblePID == nil
                if belongs, ProcessTable.isSandboxed(pid) { continue }
                kill(pid, SIGKILL)
                state.seen[pid] = nil
                state.members[pid] = nil
                if state.preexisting.remove(pid) == nil { escapes.append(escape) }
            }
            return (escapes, state.onEscape)
        }
        guard let handler, !escapes.isEmpty else { return }
        Task { @MainActor in
            for escape in escapes { handler(escape) }
        }
    }

    /// 第一次看到的进程和哪个会话有关：
    /// - 进程组是会话的（会话主进程是组长，派生的进程默认留在组里，主进程退出后也不变）；
    /// - 父进程是会话里的进程（离开了进程组的，比如调用过 setsid）；
    /// - 负责进程是会话里的进程（系统代 App 启动的 XPC 服务）。
    /// 只是“有关”，是否允许运行还要看它在不在沙盒中
    private static func relatedSession(_ pid: pid_t, in state: State) -> pid_t? {
        if let lineage = ProcessTable.lineage(of: pid) {
            if state.sessions.contains(lineage.group) { return lineage.group }
            if let parent = state.members[lineage.parent], !parent.exited { return parent.session }
        }
        if let responsible = ProcessTable.responsiblePID(of: pid), responsible != pid,
           let member = state.members[responsible], !member.exited {
            return member.session
        }
        return nil
    }

    /// 单独判断一个进程是否受管理（测试用；守卫自己在第一次看到进程时就确定归属）
    static func isManaged(_ pid: pid_t, sessions: Set<pid_t>) -> Bool {
        guard ProcessTable.isSandboxed(pid) else { return false }
        guard Private.responsiblePID != nil else { return true }
        var state = State()
        state.sessions = sessions
        for session in sessions { state.members[session] = Member(session: session) }
        return sessions.contains(pid) || relatedSession(pid, in: state) != nil
    }

    private static func prune(_ state: inout State, alive: Set<pid_t>) {
        state.seen = state.seen.filter { alive.contains($0.key) }
        state.preexisting.formIntersection(alive)
        for (pid, member) in state.members where !alive.contains(pid) {
            if member.exited { state.members[pid] = nil } else { state.members[pid]?.exited = true }
        }
    }

    /// 进程是不是盒子里的程序：可执行文件在盒子或盒子挂载的卷上，或者是解释器、运行的脚本在那里
    private static func boxProcess(_ pid: pid_t, path: String, roots: [String], volumes: [String: String]) -> Escape? {
        if let owner = owner(of: path, roots: roots, volumes: volumes) { return Escape(path: path, owner: owner) }
        if let script = ProcessTable.script(of: pid, executable: path),
           let owner = owner(of: script, roots: roots, volumes: volumes) {
            return Escape(path: script, owner: owner)
        }
        return nil
    }

    private static func owner(of path: String, roots: [String], volumes: [String: String]) -> String? {
        if roots.contains(where: { path.hasPrefix($0) }) { return path }
        return volumes.first { path.hasPrefix($0.key) }?.value
    }

    private static func transient(_ path: String) -> Bool {
        path.hasSuffix("/xpcproxy") || path.hasSuffix("/sandbox-exec") || path.isEmpty
    }
}
