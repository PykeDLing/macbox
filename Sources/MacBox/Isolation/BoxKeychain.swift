import Foundation
import Synchronization

/// 每个盒子一个独立钥匙串。
///
/// App 在重定向后的主目录里找 `Library/Keychains/login.keychain-db` 作为默认钥匙串，
/// 这里放一个指向 `box.keychain-db` 的符号链接（名为 login 的钥匙串无法用密码解锁），
/// 这样 App 存的登录凭证、设备 ID 都留在盒子里，不会进你的「登录」钥匙串。
///
/// 你的钥匙串搜索列表是借来的系统状态：`security create-keychain` 会把新钥匙串加进去，
/// 必须马上拿掉，否则本机的 App 会去搜一个永不上锁的盒子钥匙串，盒子删了还留下一条失效的路径
nonisolated enum BoxKeychain {
    /// security 命令。测试里用 `$security.withValue` 换成一个把搜索列表记在文件里的假命令，不碰你真实的搜索列表
    @TaskLocal static var security = "/usr/bin/security"

    /// 所有改动搜索列表的操作排队执行。导入和打开都会走到这里（第二次拖入、导入的同时打开清除过数据的盒子），
    /// 两次创建交错时，一方会把另一方刚加进列表的钥匙串当成你原有的保留下来
    private static let serializer = AsyncSerializer()

    @concurrent
    static func prepare(_ box: BoxPaths) async throws {
        try await serializer.run { try await prepareSerially(box) }
    }

    private static func prepareSerially(_ box: BoxPaths) async throws {
        try AppPaths.ensure(box.keychains)
        if !(await unlock(box)) {
            // 钥匙串不存在，或者和密码对不上（比如旧版的还原点只还原了钥匙串、没有还原密码）：
            // 换一个新的，否则应用再也打不开。旧的改名留在原处，不直接删除
            if FileManager.default.fileExists(atPath: box.boxKeychain.path) {
                try FileManager.default.moveItem(at: box.boxKeychain,
                                                 to: FileOps.uniqueURL(in: box.keychains, name: "box-unusable.keychain-db"))
            }
            try await create(box)
            guard await unlock(box) else {
                throw MacBoxError(L("无法解锁盒子的钥匙串", "Couldn’t unlock the box’s keychain"))
            }
        }
        if !FileOps.isSymlink(box.loginKeychainLink) {
            try FileOps.removeIfExists(box.loginKeychainLink)
            try FileManager.default.createSymbolicLink(atPath: box.loginKeychainLink.path,
                                                       withDestinationPath: box.boxKeychain.lastPathComponent)
        }
    }

    /// 把位于 root 之下的钥匙串从你的搜索列表里拿掉，包括文件已经不存在的（盒子删除后留下的）。
    /// 启动时调用：旧版 MacBox 的创建竞争、在 create-keychain 和移出列表之间崩溃，都会把盒子钥匙串留在列表里。
    /// 尽力而为，失败只记日志，不挡启动
    @concurrent
    static func removeStaleSearchListEntries(under root: URL) async {
        let base = resolvedPath(root.path)
        // 防呆：root 是根目录、或者包含你自己的钥匙串目录时什么也不做，免得把「登录」钥匙串也拿掉
        let ownKeychains = resolvedPath(AppPaths.realHome.appending(path: "Library/Keychains").path)
        guard base != "/", !isPath(ownKeychains, under: base) else { return }
        do {
            try await serializer.run {
                try await removeFromSearchList { isPath($0, under: base) }
            }
        } catch {
            NSLog("MacBox: 清理钥匙串搜索列表失败：\(error.localizedDescription)")
        }
    }

    /// 用保存的密码解锁；钥匙串或密码不存在、密码不对时返回 false
    private static func unlock(_ box: BoxPaths) async -> Bool {
        guard FileManager.default.fileExists(atPath: box.boxKeychain.path), let password = savedPassword(box) else { return false }
        return (try? await Shell.run(security, ["unlock-keychain", "-p", password, box.boxKeychain.path])) != nil
    }

    /// 保存的密码（非空才算）。密码文件在盒子目录里，App 改得到：换成指向盒子外的符号链接时当作没有，
    /// 不顺着它把别的文件读出来、再当作命令行参数交给 security
    private static func savedPassword(_ box: BoxPaths) -> String? {
        guard let data = FileOps.regularFileContents(box.keychainPassword),
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }

    /// 只在 serializer 里调用
    private static func create(_ box: BoxPaths) async throws {
        let password = try password(for: box)
        let keychain = box.boxKeychain
        let created: Result<Void, Error>
        do {
            try await Shell.run(security, ["create-keychain", "-p", password, keychain.path])
            created = .success(())
        } catch {
            created = .failure(error)
        }
        // create-keychain 会把新钥匙串加进你的搜索列表（失败时也可能已经加了），不论成败都马上拿掉。
        // 只拿掉这一项，不写回创建前的快照：快照会抹掉这期间其他工具对列表的改动。
        // 放在单独的任务里：调用方被取消时 Shell.run 会直接结束子进程，这一步却必须做完
        let removed = await Task {
            let target = resolvedPath(keychain.path)
            try await removeFromSearchList { $0 == target }
        }.result
        try created.get()
        try removed.get()
        try await Shell.run(security, ["set-keychain-settings", keychain.path]) // 不自动锁定
    }

    /// 盒子一辈子只用一个密码：已有（非空）就沿用，没有才生成并保存。
    /// 这样清除数据之前、之后做的还原点，自愈时新建的钥匙串，都和同一个密码配套，还原后不会再解不开
    private static func password(for box: BoxPaths) throws -> String {
        if let existing = savedPassword(box) { return existing }
        let password = UUID().uuidString + UUID().uuidString
        // 空的、读不出的旧文件先删掉：是符号链接时只删链接本身，不顺着它把密码写到别处
        try? FileOps.removeTree(box.keychainPassword)
        guard FileManager.default.createFile(atPath: box.keychainPassword.path, contents: Data(password.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw MacBoxError(L("无法保存钥匙串密码", "Couldn’t save the keychain password"))
        }
        return password
    }

    // MARK: - 搜索列表

    /// 从你的搜索列表里拿掉满足条件的项（按真实路径判断），其余原样保留、顺序不变；没有要拿掉的就不写
    private static func removeFromSearchList(where matches: (String) -> Bool) async throws {
        let current = try await currentSearchList()
        let kept = current.filter { !matches(resolvedPath($0)) }
        guard kept.count != current.count else { return }
        try await Shell.run(security, ["list-keychains", "-d", "user", "-s"] + kept)
    }

    private static func currentSearchList() async throws -> [String] {
        let output = try await Shell.run(security, ["list-keychains", "-d", "user"]).output
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// 真实路径，用来比较搜索列表里的项：security 记下的可能是 /private/var/… 或展开过的写法。
    /// 文件已经不存在时（创建失败、盒子已删除）解析仍然存在的上级目录，再接上其余部分
    private static func resolvedPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(FileOps.realPath(existing)) { ($0 as NSString).appendingPathComponent($1) }
    }

    private static func isPath(_ path: String, under base: String) -> Bool {
        path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

/// 异步互斥：同一时刻只有一个任务在里面，其余按到达顺序排队。
/// 不能用 actor：actor 方法在每个 await 处都会让出，两次创建照样交错
private nonisolated final class AsyncSerializer: Sendable {
    private struct State {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func run<T>(_ work: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            let enter = state.withLock { state in
                if state.busy {
                    state.waiters.append(continuation)
                    return false
                }
                state.busy = true
                return true
            }
            if enter { continuation.resume() }
        }
    }

    /// 有人在等就直接把“占用”交给它（busy 保持 true），中间不会被别人插队
    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.waiters.isEmpty {
                state.busy = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
