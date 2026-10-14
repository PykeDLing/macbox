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
/// 进程属于哪个会话，在第一次看到它时确定并记下来（见 admission），之后不再重新推导：
/// 会话主进程退出后，留下的进程改为对自己负责、父进程变成 launchd，再推导就认不出来了，
/// 而启动器式的主程序、“重启以生效”的辅助进程正是在主进程退出后才派生新进程。
/// 会话里的进程一 fork 就记下新进程（见 watchForks），不等下一轮检查：几毫秒就结束的系统工具也能认出来
nonisolated final class EscapeGuard: Sendable {
    static let shared = EscapeGuard()

    /// 被结束的逃逸进程
    struct Escape: Sendable {
        /// 可执行文件路径（解释器运行的脚本是脚本的路径）
        let path: String
        /// 它属于哪个盒子：位于盒子里时是它自己的路径，位于卷上时是挂载这个卷的映像文件路径
        let owner: String
    }

    /// 进程属于哪个会话、是怎么认出来的
    struct Membership: Equatable, Sendable {
        /// 所属会话的主进程
        let session: pid_t
        /// 继承了盒子的沙盒规则：会话主进程本身，以及经由进程组、父进程认出的（都由会话里的进程派生，
        /// 沙盒规则随 fork、exec 继承，去不掉）。经由负责进程认出的不算：系统代 App 启动的 XPC 服务
        /// （WebKit 的 WebContent、GPU、Networking）由 launchd 启动，负责进程虽然是 App，带的却是它们自己的沙盒
        let inherited: Bool
    }

    /// 会话里的一个进程
    private struct Member {
        let membership: Membership
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
        /// 盯着会话里还在运行的进程的 fork：一派生就把新进程记为成员（见 forked）
        var forkWatchers: [pid_t: any DispatchSourceProcess] = [:]
        /// 上次 MacBox 运行时遗留下来的盒子进程：照样结束，但不当作逃逸回调（不记录、不在隔离中重新打开）
        var preexisting: Set<pid_t> = []
        var ticks = 0
        var onEscape: (@MainActor @Sendable (Escape) -> Void)?
        var loop: Task<Void, Never>?

        /// 还在运行的成员的归属（上次清理时已经不在的不算：它的 pid 可能已被新进程重用）
        func liveMembership(of pid: pid_t) -> Membership? {
            members[pid].flatMap { $0.exited ? nil : $0.membership }
        }
    }

    private let state = Mutex(State())
    /// fork 事件在这里处理
    private let forkQueue = DispatchQueue(label: "MacBox.EscapeGuard.forks", qos: .userInitiated)
    /// 守卫的目录，nil 时是 AppPaths.boxes（测试时换成别处，不碰真实的盒子）
    private let boxesOverride: URL?

    init(boxes: URL? = nil) {
        boxesOverride = boxes
    }

    deinit {
        state.withLock { state in
            state.forkWatchers.values.forEach { $0.cancel() }
            state.forkWatchers.removeAll()
        }
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
            if owner(of: path, roots: roots, volumes: [:]) != nil { return true }
            return ProcessTable.isInterpreter(path) && scriptInBox(pid, executable: path, roots: roots, volumes: [:]) != nil
        })
    }

    /// 登记一个会话主进程（启动后立即调用）：它和它派生的、在沙盒中的程序都允许运行
    func register(session pid: pid_t) {
        state.withLock { state in
            state.sessions.insert(pid)
            state.members[pid] = Member(membership: Membership(session: pid, inherited: true))
            watchForks(of: pid, in: &state)
            recordChildren(of: pid, in: &state) // 启动和登记之间已经派生的
        }
    }

    /// 会话结束（它的进程都已退出）：它的进程不再受管理。万一还有盒子里的程序在运行，下次检查时按逃逸结束
    func unregister(session pid: pid_t) {
        state.withLock { state in
            state.sessions.remove(pid)
            for (member, info) in state.members where info.membership.session == pid {
                state.members[member] = nil
                state.seen[member] = nil
                state.forkWatchers.removeValue(forKey: member)?.cancel()
            }
        }
    }

    /// 进程属于哪个会话（含最近约 10 秒内退出的）。只给继承了盒子沙盒规则的进程（见 Membership.inherited）：
    /// 拦截记录归属用它，别的沙盒报告的拒绝不该算到盒子头上。
    /// 守卫没见过这个进程（守卫没在运行、进程在两次检查之间就结束了且不是会话里的进程派生的）时为 nil
    func session(of pid: pid_t) -> pid_t? {
        state.withLock { state in
            state.members[pid].flatMap { $0.membership.inherited ? $0.membership.session : nil }
        }
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
        // 先在锁里按可执行文件路径检查。解释器进程记下来，到锁外读出它运行的脚本：解析脚本路径要碰文件系统，
        // 路径在没响应的网络卷上时会卡住，拿着锁就会连带卡住登记、注销会话（主线程）和拦截记录的归属
        let (escapes, interpreters, roots, volumes) = state.withLock { state in
            state.ticks += 1
            if state.ticks % 200 == 0 { prune(&state, alive: Set(pids)) } // 每 10 秒清理已退出的进程
            let recheck = state.ticks % 10 == 0 // 每半秒复查一次路径（整张进程表约 1ms）
            var escapes: [Escape] = []
            var interpreters: [(pid: pid_t, executable: String)] = []
            for pid in pids {
                let previous = state.seen[pid]
                if let previous, !Self.transient(previous), !recheck { continue }
                guard let path = ProcessTable.path(of: pid) else { continue }
                if let previous, previous == path, !Self.transient(path) { continue }
                state.seen[pid] = path
                if !state.sessions.isEmpty, state.members[pid] == nil {
                    if let membership = Self.admission(pid, lineage: ProcessTable.lineage(of: pid),
                                                       responsible: ProcessTable.responsiblePID(of: pid),
                                                       sessions: state.sessions, membership: { state.liveMembership(of: $0) }) {
                        state.members[pid] = Member(membership: membership)
                        watchForks(of: pid, in: &state)
                    }
                }
                if let owner = Self.owner(of: path, roots: state.roots, volumes: state.volumes) {
                    if let escape = Self.enforce(pid, Escape(path: path, owner: owner), in: &state) { escapes.append(escape) }
                } else if ProcessTable.isInterpreter(path) {
                    interpreters.append((pid, path))
                }
            }
            return (escapes, interpreters, state.roots, state.volumes)
        }
        let scripts = interpreters.compactMap { pid, executable in
            Self.scriptInBox(pid, executable: executable, roots: roots, volumes: volumes).map { (pid, executable, $0) }
        }
        let (scriptEscapes, handler) = state.withLock { state -> ([Escape], (@MainActor @Sendable (Escape) -> Void)?) in
            var escapes: [Escape] = []
            // 解析期间进程可能已经 exec 成别的程序、被重新检查过：只处理还是同一个程序的
            for (pid, executable, escape) in scripts where state.seen[pid] == executable {
                if let escape = Self.enforce(pid, escape, in: &state) { escapes.append(escape) }
            }
            return (escapes, state.onEscape)
        }
        let all = escapes + scriptEscapes
        guard let handler, !all.isEmpty else { return }
        Task { @MainActor in
            for escape in all { handler(escape) }
        }
    }

    /// 盒子里的程序：属于会话且在沙盒中的放行，否则立即结束。返回要回调的逃逸（遗留进程不回调）
    private static func enforce(_ pid: pid_t, _ escape: Escape, in state: inout State) -> Escape? {
        // 负责进程接口不可用时退回只看沙盒（不误杀）
        let belongs = state.members[pid] != nil || Private.responsiblePID == nil
        if belongs, ProcessTable.isSandboxed(pid) { return nil }
        kill(pid, SIGKILL)
        state.seen[pid] = nil
        state.members[pid] = nil
        state.forkWatchers.removeValue(forKey: pid)?.cancel()
        return state.preexisting.remove(pid) == nil ? escape : nil
    }

    /// 第一次看到的进程和哪个会话有关（纯函数）：
    /// - 进程组是会话的（会话主进程是组长，派生的进程默认留在组里，主进程退出后也不变）→ 继承了沙盒规则；
    /// - 父进程是会话里的进程（离开了进程组的，比如调用过 setsid）→ 和父进程一样；
    /// - 负责进程是会话里的进程（系统代 App 启动的 XPC 服务）→ 没有继承。
    /// 只是“有关”，是否允许运行还要看它在不在沙盒中。membership 只给出还在运行的成员（已退出的 pid 可能被重用）
    static func admission(_ pid: pid_t, lineage: ProcessTable.Lineage?, responsible: pid_t?, sessions: Set<pid_t>,
                          membership: (pid_t) -> Membership?) -> Membership? {
        if let lineage {
            if sessions.contains(lineage.group) { return Membership(session: lineage.group, inherited: true) }
            if let parent = membership(lineage.parent) { return parent }
        }
        if let responsible, responsible != pid, let owner = membership(responsible) {
            return Membership(session: owner.session, inherited: false)
        }
        return nil
    }

    /// 单独判断一个进程是否受管理（测试用；守卫自己在第一次看到进程时就确定归属）
    static func isManaged(_ pid: pid_t, sessions: Set<pid_t>) -> Bool {
        guard ProcessTable.isSandboxed(pid) else { return false }
        guard Private.responsiblePID != nil else { return true }
        let related = admission(pid, lineage: ProcessTable.lineage(of: pid), responsible: ProcessTable.responsiblePID(of: pid),
                                sessions: sessions) { sessions.contains($0) ? Membership(session: $0, inherited: true) : nil }
        return sessions.contains(pid) || related != nil
    }

    // MARK: - 盯着 fork

    /// 盯着一个会话进程的 fork。盒子里的 App 调用的系统工具（cp、launchctl、touch）往往几毫秒就结束，
    /// 守卫每 50ms 一轮的检查多半看不到它们，它们的拦截记录晚到时就认不出是谁的（名字不在盒子里）。
    /// 派生的一刻就记下来，不用加快检查。只在锁里调用
    private func watchForks(of pid: pid_t, in state: inout State) {
        guard state.forkWatchers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.fork, .exit], queue: forkQueue)
        source.setEventHandler { [weak self] in self?.forked(pid) }
        state.forkWatchers[pid] = source
        source.resume()
    }

    /// 被盯着的进程派生了新进程（或者退出了）：趁新进程还在，把它记为同一会话的成员，并且也盯着它
    private func forked(_ pid: pid_t) {
        state.withLock { state in
            recordChildren(of: pid, in: &state)
            // 已经退出：不用再盯（归属留到清理时再去掉，拦截记录可能晚到）
            if ProcessTable.lineage(of: pid).map({ $0.isZombie }) ?? true {
                state.forkWatchers.removeValue(forKey: pid)?.cancel()
            }
        }
    }

    /// 把成员 pid 的子进程、它所在会话进程组里的进程记为成员。只在锁里调用
    private func recordChildren(of pid: pid_t, in state: inout State) {
        guard let parent = state.members[pid], !parent.exited else { return }
        let session = parent.membership.session
        var found = ProcessTable.children(of: pid).map { ($0, parent.membership) }
        if state.sessions.contains(session) {
            found += ProcessTable.pids(inGroup: session).map { ($0, Membership(session: session, inherited: true)) }
        }
        for (child, membership) in found where state.members[child] == nil {
            state.members[child] = Member(membership: membership)
            watchForks(of: child, in: &state)
        }
    }

    private func prune(_ state: inout State, alive: Set<pid_t>) {
        state.seen = state.seen.filter { alive.contains($0.key) }
        state.preexisting.formIntersection(alive)
        for (pid, member) in state.members where !alive.contains(pid) {
            if member.exited { state.members[pid] = nil } else { state.members[pid]?.exited = true }
        }
        for pid in state.forkWatchers.keys where !alive.contains(pid) || state.members[pid] == nil {
            state.forkWatchers.removeValue(forKey: pid)?.cancel()
        }
    }

    // MARK: - 路径

    /// 解释器运行的脚本在不在盒子里。先按参数原样粗筛，可能通向盒子的才解析符号链接：
    /// 每个新出现的解释器进程都要查，`python3 /Volumes/NAS/x.py` 这样的路径在网络卷没响应时，解析会卡住很久。
    /// 盒子的真实路径在主目录下（测试时在 /private/tmp 下），能经由符号链接通到那里的只有
    /// /Users、/tmp、/var、/private 下的路径（还有盒子挂载的卷）
    private static func scriptInBox(_ pid: pid_t, executable: String, roots: [String], volumes: [String: String]) -> Escape? {
        guard let argument = ProcessTable.scriptArgument(of: pid, executable: executable) else { return nil }
        let candidates = roots + Array(volumes.keys) + ["/Users/", "/tmp/", "/var/", "/private/"]
        guard candidates.contains(where: { argument.hasPrefix($0) }), let resolved = realpath(argument, nil) else { return nil }
        defer { free(resolved) }
        let script = String(cString: resolved)
        return owner(of: script, roots: roots, volumes: volumes).map { Escape(path: script, owner: $0) }
    }

    private static func owner(of path: String, roots: [String], volumes: [String: String]) -> String? {
        if roots.contains(where: { path.hasPrefix($0) }) { return path }
        return volumes.first { path.hasPrefix($0.key) }?.value
    }

    private static func transient(_ path: String) -> Bool {
        path.hasSuffix("/xpcproxy") || path.hasSuffix("/sandbox-exec") || path.isEmpty
    }
}
