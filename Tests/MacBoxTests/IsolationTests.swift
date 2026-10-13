import Foundation
import Testing
@testable import MacBox

@Suite("本机隔离")
struct IsolationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    func makeBox(shareDownloads: Bool = false) throws -> (BoxPaths, BoxConfig) {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        try AppPaths.ensure(paths.home)
        try AppPaths.ensure(paths.tmp)
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "dev.macboxtest.app", appFolderName: "T.app")
        config.shareDownloads = shareDownloads
        return (paths, config)
    }

    /// 在盒子的沙盒中运行一段 shell，返回输出
    func sandboxed(_ paths: BoxPaths, _ config: BoxConfig, _ script: String) async throws -> String {
        let profile = SandboxProfile.make(box: paths, config: config)
        var options = ChildProcess.Options()
        options.environment["HOME"] = paths.home.path
        options.output = .pipe
        options.error = .pipe
        let child = try ChildProcess.spawn("/usr/bin/sandbox-exec", ["-p", profile, "/bin/sh", "-c", script], options: options)
        async let output = child.standardOutput.collect()
        async let error = child.standardError.collect()
        _ = await (output, error)
        _ = await child.waitForExit()
        return String(decoding: await output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("写入：只能写盒子；不共享「下载」时也不能写「下载」")
    func writes() async throws {
        let (paths, config) = try makeBox()
        let home = AppPaths.realHome.path
        let probe = "\(home)/Desktop/.macbox-probe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: probe) }
        #expect(try await sandboxed(paths, config, "echo hi > '\(paths.url.path)/w' && cat '\(paths.url.path)/w'") == "hi")
        #expect(try await sandboxed(paths, config, "touch '\(probe)' 2>/dev/null && echo leak || echo denied") == "denied")
        #expect(try await sandboxed(paths, config, "touch '\(home)/Downloads/.macbox-probe' 2>/dev/null && echo leak || echo denied") == "denied")
        #expect(try await sandboxed(paths, config, "echo $HOME") == paths.home.path)
    }

    @Test("读取：其他盒子、SSH 密钥、其他 App 的数据都读不到")
    func reads() async throws {
        let (paths, config) = try makeBox()
        let home = AppPaths.realHome.path
        for target in ["\(home)/.ssh", "\(home)/Library/Application Support", "\(home)/Library/Containers"] {
            let output = try await sandboxed(paths, config, "ls '\(target)' >/dev/null 2>&1 && echo readable || echo denied")
            #expect(output == "denied" || !FileManager.default.fileExists(atPath: target), "\(target)")
        }
    }

    @Test("盒子路径带引号和反斜杠时规则仍然有效")
    func quoting() async throws {
        let paths = BoxPaths(url: root.appending(path: "we\"ird\\name.box"))
        try AppPaths.ensure(paths.home)
        let config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "x", appFolderName: "T.app")
        #expect(try await sandboxed(paths, config, "echo x > '\(paths.url.path)/a' && echo ok") == "ok")
    }

    @Test("守卫：只有登记过的会话派生、且在沙盒中的进程才算受管理")
    func guardPolicy() async throws {
        let (paths, config) = try makeBox()
        var options = ChildProcess.Options()
        options.newProcessGroup = true
        options.disclaimResponsibility = true
        let session = try ChildProcess.spawn("/usr/bin/sandbox-exec",
                                             ["-p", SandboxProfile.make(box: paths, config: config), "/bin/sleep", "5"],
                                             options: options)
        let plain = try ChildProcess.spawn("/bin/sleep", ["5"], options: options)
        defer {
            session.signal(SIGKILL)
            plain.signal(SIGKILL)
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(ProcessTable.responsiblePID(of: session.pid) == session.pid)
        #expect(!EscapeGuard.isManaged(session.pid, sessions: []), "没登记：例如 MacBox 崩溃后遗留的进程")
        #expect(EscapeGuard.isManaged(session.pid, sessions: [session.pid]))
        #expect(!EscapeGuard.isManaged(plain.pid, sessions: [plain.pid]), "不在沙盒中")
    }

    @Test("系统日志：多个订阅共用一个 log 进程，并能收到本盒子的拒绝记录")
    func sharedLogStream() async throws {
        let (paths, config) = try makeBox()
        func logProcesses() async -> Int {
            let children = (try? await Shell.run("/usr/bin/pgrep", ["-P", "\(getpid())", "-x", "log"]))?.output ?? ""
            return children.split(separator: "\n").count
        }
        let first = await ViolationMonitor.events(boxPrefix: FileOps.realPath(paths.url), processNames: ["touch"])
        let second = await ViolationMonitor.events(boxPrefix: "/nonexistent/", processNames: [])
        #expect(await logProcesses() == 1)

        // 其他并行的测试也会让 touch 被拒绝，只等这一条
        let received = Task { () -> BlockEvent? in
            for await event in first where event.target.hasSuffix("dev.macboxtest.plist") { return event }
            return nil
        }
        _ = try await sandboxed(paths, config, "touch '\(AppPaths.realHome.path)/Library/LaunchAgents/dev.macboxtest.plist'")
        let timeout = Task {
            try await Task.sleep(for: .seconds(8))
            received.cancel()
        }
        let event = await received.value
        timeout.cancel()
        #expect(event?.kind == .autostart)
        _ = second
    }
}
