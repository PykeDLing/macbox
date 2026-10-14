import Foundation
import Synchronization
import Testing
@testable import MacBox

/// 守卫会结束进程：每个测试用自己的守卫和自己的目录（在 MACBOX_DATA_ROOT 下），
/// 不碰真实的盒子，也不影响其他测试的盒子
@Suite("守卫", .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
final class GuardTests {
    let boxes = AppPaths.root.appending(path: "GuardTests-\(UUID().uuidString)/Boxes", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: boxes.deletingLastPathComponent())
    }

    final class Escapes: Sendable {
        private let paths = Mutex<[String]>([])
        func append(_ path: String) { paths.withLock { $0.append(path) } }
        var all: [String] { paths.withLock { $0 } }
    }

    /// 盒子、盒子里 App 包内的小程序（真实路径）、盒子的沙盒规则
    func makeBox() async throws -> (paths: BoxPaths, stub: String, profile: String) {
        let paths = BoxPaths(url: boxes.appending(path: "\(UUID().uuidString).box", directoryHint: .isDirectory))
        try AppPaths.ensure(paths.home)
        try AppPaths.ensure(paths.tmp)
        let stub = paths.appDirectory.appending(path: "S.app/Contents/MacOS/stub")
        try await TestStub.install(at: stub)
        let config = BoxConfig(id: UUID(), name: "S", bundleIdentifier: "dev.macboxtest.guard", appFolderName: "S.app")
        return (paths, FileOps.realPath(stub), SandboxProfile.make(box: paths, config: config))
    }

    func startGuard(preexisting: Set<pid_t> = []) -> (EscapeGuard, Escapes) {
        let watcher = EscapeGuard(boxes: boxes)
        let escapes = Escapes()
        watcher.start(preexisting: preexisting) { escapes.append($0.path) }
        return (watcher, escapes)
    }

    /// 和 IsolatedSession 一样启动会话：新进程组、disclaim、沙盒
    func sessionOptions(_ paths: BoxPaths) -> ChildProcess.Options {
        var options = ChildProcess.Options()
        options.environment["STUB_DIR"] = paths.tmp.path
        options.newProcessGroup = true
        options.disclaimResponsibility = true
        return options
    }

    @Test("会话主进程退出后，留下的进程再派生的程序照常运行；重新检查也不会结束已确认的进程")
    func helpersAfterMainExit() async throws {
        let (paths, stub, profile) = try await makeBox()
        let (watcher, escapes) = startGuard()
        defer { watcher.stop() }
        // 主进程启动 mid 后 0.3 秒退出；mid 在 1.2 秒时（主进程已退出）再启动 worker
        let main = try ChildProcess.spawn("/usr/bin/sandbox-exec", [
            "-p", profile, stub, "main", "0", "300", "mid", "1200", "4000", "worker", "0", "4000",
        ], options: sessionOptions(paths))
        watcher.register(session: main.pid)
        defer {
            main.signal(SIGKILL)
            watcher.unregister(session: main.pid)
        }
        _ = await main.waitForExit()
        let workerFile = paths.tmp.appending(path: "worker")
        #expect(await eventually { readPID(workerFile) != nil })
        try await Task.sleep(for: .milliseconds(300)) // 守卫检查过几轮
        let worker = try #require(readPID(workerFile))
        let mid = try #require(readPID(paths.tmp.appending(path: "mid")))
        #expect(isRunning(worker), "主进程退出后派生的进程被结束了")
        #expect(isRunning(mid))

        watcher.recheckAll() // 卷变化时所有进程重新检查
        try await Task.sleep(for: .milliseconds(200))
        #expect(isRunning(worker) && isRunning(mid), "重新检查时结束了已确认属于会话的进程")
        #expect(escapes.all.isEmpty)
    }

    @Test("会话里的程序启动另一个 App 包里的程序（负责进程是它自己）也算会话的")
    func sessionChildInAnotherBundle() async throws {
        let (paths, stub, profile) = try await makeBox()
        let main = try ChildProcess.spawn("/usr/bin/sandbox-exec", [
            "-p", profile, "/bin/sh", "-c", "'\(stub)' child 0 3000; true",
        ], options: sessionOptions(paths))
        defer { main.signal(SIGKILL) }
        let childFile = paths.tmp.appending(path: "child")
        #expect(await eventually { readPID(childFile) != nil })
        let child = try #require(readPID(childFile))
        #expect(EscapeGuard.isManaged(child, sessions: [main.pid]))
        #expect(!EscapeGuard.isManaged(child, sessions: []))
    }

    @Test("先启动系统程序、再 exec 成盒子里的程序，也会被结束")
    func execChainIntoBoxExecutable() async throws {
        let (paths, stub, _) = try await makeBox()
        let (watcher, escapes) = startGuard()
        defer { watcher.stop() }
        var options = ChildProcess.Options()
        options.environment["STUB_DIR"] = paths.tmp.path
        let chain = try ChildProcess.spawn("/bin/sh", ["-c", "sleep 0.6; exec '\(stub)' chain 0 5000"], options: options)
        defer { chain.signal(SIGKILL) }
        // 系统程序阶段不算盒子里的程序；exec 之后（守卫每半秒复查一次路径）被结束
        #expect(await eventually(.seconds(3)) { chain.hasExited }, "exec 成盒子里的程序后没被发现")
        #expect(await chain.waitForExit() == 128 + SIGKILL)
        #expect(await eventually { escapes.all == [stub] })
    }

    @Test("主程序是脚本的 App 被直接打开（进程是解释器）也会被结束")
    func scriptOpenedDirectly() async throws {
        let (paths, _, _) = try await makeBox()
        let script = paths.appDirectory.appending(path: "T.app/Contents/MacOS/launch")
        try AppPaths.ensure(script.deletingLastPathComponent())
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let (watcher, escapes) = startGuard()
        defer { watcher.stop() }

        let process = try ChildProcess.spawn(script.path, [])
        defer { process.signal(SIGKILL) }
        #expect(await eventually(.seconds(2)) { process.hasExited }, "解释器运行的盒子脚本没被发现")
        #expect(await eventually { escapes.all.contains(FileOps.realPath(script)) })
    }

    @Test("开始守卫前就在运行的盒子进程：静默结束，不当作逃逸")
    func preexistingKilledSilently() async throws {
        let (_, stub, _) = try await makeBox()
        let old = try ChildProcess.spawn(stub, ["old", "0", "5000"])
        defer { old.signal(SIGKILL) }
        let (watcher, escapes) = startGuard(preexisting: [old.pid])
        defer { watcher.stop() }
        let new = try ChildProcess.spawn(stub, ["new", "0", "5000"])
        defer { new.signal(SIGKILL) }

        #expect(await eventually { old.hasExited && new.hasExited })
        try await Task.sleep(for: .milliseconds(200)) // 回调在主线程
        #expect(escapes.all == [stub], "只有开始守卫后才出现的那个算逃逸")
    }

    @Test("盒子进程快照：可执行文件或运行的脚本在盒子里的")
    func boxProcessesSnapshot() async throws {
        let paths = BoxPaths.new(id: UUID())
        defer { try? FileManager.default.removeItem(at: paths.url) }
        let stub = paths.appDirectory.appending(path: "S.app/Contents/MacOS/stub")
        try await TestStub.install(at: stub)
        let script = paths.appDirectory.appending(path: "S.app/Contents/MacOS/launch")
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let binary = try ChildProcess.spawn(stub.path, ["snapshot", "0", "5000"])
        let scripted = try ChildProcess.spawn(script.path, [])
        let outside = try ChildProcess.spawn("/bin/sleep", ["5"])
        defer { [binary, scripted, outside].forEach { $0.signal(SIGKILL) } }
        try await Task.sleep(for: .milliseconds(300))

        let snapshot = EscapeGuard.boxProcessesNow()
        #expect(snapshot.contains(binary.pid))
        #expect(snapshot.contains(scripted.pid))
        #expect(!snapshot.contains(outside.pid))
    }
}
