import Foundation
import Synchronization
import Testing
@testable import MacBox

@Suite("本机隔离")
struct IsolationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    func makeBox(shareDownloads: Bool = false) throws -> (BoxPaths, BoxConfig) {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        // 和启动前准备好的一样：这几个文件夹本身沙盒里的进程建不了（见 SandboxProfile）
        for folder in [paths.keychains, paths.tmp, paths.appDirectory] { try AppPaths.ensure(folder) }
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "dev.macboxtest.app", appFolderName: "T.app")
        config.shareDownloads = shareDownloads
        return (paths, config)
    }

    /// 在盒子的沙盒中运行一段 shell，返回输出
    func sandboxed(_ paths: BoxPaths, _ config: BoxConfig, _ script: String, environment: [String: String] = [:]) async throws -> String {
        let profile = SandboxProfile.make(box: paths, config: config)
        var options = ChildProcess.Options()
        options.environment.merge(environment) { $1 }
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

    @Test("写入：盒子里只能写主目录、临时目录和 App；不共享「下载」时也不能写「下载」")
    func writes() async throws {
        let (paths, config) = try makeBox()
        let home = AppPaths.realHome.path
        let probe = "\(home)/Desktop/.macbox-probe-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: probe) }
        func canWrite(_ path: String) async throws -> Bool {
            try await sandboxed(paths, config, "mkdir -p \"$(dirname '\(path)')\" 2>/dev/null; echo x > '\(path)' 2>/dev/null && echo yes || echo no") == "yes"
        }
        for writable in ["Home/w", "tmp/w", "App/T.app/w"] {
            #expect(try await canWrite("\(paths.url.path)/\(writable)"), "\(writable)")
        }
        // MacBox 自己的记录：App 改了它们，MacBox 收尾时会照着改过的内容去删改沙盒外的文件
        for control in ["box.json", "w", "Prefs/.lease.json", "Prefs/.native/x.plist", ".keychain-password", "RestorePoint/Home/w"] {
            #expect(try await !canWrite("\(paths.url.path)/\(control)"), "\(control)")
        }
        // 里面照常：新建、改名、删除文件夹和文件
        let box = paths.url.path
        let inside = try await sandboxed(paths, config, """
        for d in '\(box)/App' '\(box)/Home' '\(box)/tmp' '\(box)/Home/Library/Keychains'; do
          mkdir -p "$d/a" && mv "$d/a" "$d/b" && echo x > "$d/b/f" && mv "$d/b/f" "$d/b/g" && rm "$d/b/g" && rmdir "$d/b" && echo ok
        done
        """)
        #expect(inside == "ok\nok\nok\nok")
        #expect(try await sandboxed(paths, config, "touch '\(probe)' 2>/dev/null && echo leak || echo denied") == "denied")
        #expect(try await sandboxed(paths, config, "touch '\(home)/Downloads/.macbox-probe' 2>/dev/null && echo leak || echo denied") == "denied")
        #expect(try await sandboxed(paths, config, "echo $HOME") == paths.home.path)
    }

    @Test("盒子里可写的文件夹本身不能删除、改名、换成符号链接", arguments: ["App", "Home", "tmp", "Home/Library", "Home/Library/Keychains"])
    func boxSkeletonIsFixed(folder: String) async throws {
        let (paths, config) = try makeBox()
        // 只留下这一个空文件夹（和它的上级）：rmdir 成不成功只取决于规则
        try FileManager.default.removeItem(at: paths.url)
        let target = paths.url.appending(path: folder).path
        try AppPaths.ensure(URL(fileURLWithPath: target))
        let output = try await sandboxed(paths, config, """
        rmdir '\(target)' 2>/dev/null && echo rmdir
        mv '\(target)' '\(target).old' 2>/dev/null && echo mv
        [ -d '\(target)' ] && [ ! -L '\(target)' ] && echo intact
        """)
        #expect(output == "intact", "\(folder)")
        // 不存在时（比如在线安装器的盒子还没有 App 文件夹）也不能在原处放一个符号链接
        try FileManager.default.removeItem(atPath: target)
        let link = try await sandboxed(paths, config, "ln -s /Applications '\(target)' 2>/dev/null && echo linked || echo denied")
        #expect(link == "denied", "\(folder)")
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test("读取：其他盒子、密钥和凭证、其他 App 的数据都读不到")
    func reads() async throws {
        let (paths, config) = try makeBox()
        let home = AppPaths.realHome.path
        let targets = [".ssh", "Library/Application Support", "Library/Containers", "Library/WebKit", "Library/Caches",
                       "Library/Saved Application State", ".config", ".docker", ".zsh_history", ".bash_history", ".netrc",
                       ".git-credentials", ".npmrc"]
        for target in targets.map({ "\(home)/\($0)" }) where FileManager.default.fileExists(atPath: target) {
            let read = "if [ -d '\(target)' ]; then ls '\(target)'; else head -c 1 '\(target)'; fi"
            let output = try await sandboxed(paths, config, "(\(read)) >/dev/null 2>&1 && echo readable || echo denied")
            #expect(output == "denied", "\(target)")
        }
    }

    @Test("读取：盒子里本机设置的备份、钥匙串密码、还原点读不到，主目录和 App 照常")
    func boxControlFilesAreHidden() async throws {
        let (paths, config) = try makeBox()
        let files = ["Prefs/.native/dev.macboxtest.native.plist": "native-login-token", ".keychain-password": "secret",
                     "RestorePoint/Home/note": "old", "Home/note": "mine", "App/T.app/Info": "app", "box.json": "{}"]
        for (path, content) in files {
            let url = paths.url.appending(path: path)
            try AppPaths.ensure(url.deletingLastPathComponent())
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) async throws -> String {
            try await sandboxed(paths, config, "cat '\(paths.url.path)/\(path)' 2>/dev/null || echo denied")
        }
        #expect(try await read("Prefs/.native/dev.macboxtest.native.plist") == "denied")
        #expect(try await read(".keychain-password") == "denied")
        #expect(try await read("RestorePoint/Home/note") == "denied")
        #expect(try await read("Home/note") == "mine")
        #expect(try await read("App/T.app/Info") == "app")
        #expect(try await read("box.json") == "{}")
    }

    @Test("新的读取限制下 AppKit 程序照常启动")
    func appKitStillLaunches() async throws {
        let (paths, config) = try makeBox()
        // JXA 里初始化 AppKit（不显示任何窗口、不出现在程序坞），读系统字体、图标、偏好设置
        let script = """
        ObjC.import('AppKit');
        const app = $.NSApplication.sharedApplication;
        app.setActivationPolicy($.NSApplicationActivationPolicyProhibited);
        const font = $.NSFont.systemFontOfSize(13);
        const icon = $.NSWorkspace.sharedWorkspace.iconForFile('/Applications');
        $.NSUserDefaults.standardUserDefaults.boolForKey('dev.macboxtest.probe');
        (font.pointSize == 13 && icon.size.width > 0) ? 'ok' : 'broken';
        """
        let output = try await sandboxed(paths, config, "/usr/bin/osascript -l JavaScript -e \"$SCRIPT\" 2>&1", environment: ["SCRIPT": script])
        #expect(output == "ok")
    }

    @Test("盒子路径带引号和反斜杠时规则仍然有效")
    func quoting() async throws {
        let paths = BoxPaths(url: root.appending(path: "we\"ird\\name.box"))
        try AppPaths.ensure(paths.home)
        let config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "x", appFolderName: "T.app")
        #expect(try await sandboxed(paths, config, "echo x > '\(paths.home.path)/a' && echo ok") == "ok")
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

    @Test("守卫认会话成员：进程组、父进程认出的继承了沙盒规则，负责进程认出的没有")
    func guardAdmission() {
        let main: pid_t = 500, helper: pid_t = 600
        let members: [pid_t: EscapeGuard.Membership] = [
            main: .init(session: main, inherited: true),
            helper: .init(session: main, inherited: true),
            700: .init(session: main, inherited: false), // 系统代 App 启动的 XPC 服务
        ]
        func admit(parent: pid_t, group: pid_t, responsible: pid_t?) -> EscapeGuard.Membership? {
            EscapeGuard.admission(900, lineage: ProcessTable.Lineage(parent: parent, group: group, isZombie: false),
                                  responsible: responsible, sessions: [main]) { members[$0] }
        }
        #expect(admit(parent: 1, group: main, responsible: 900) == .init(session: main, inherited: true), "会话进程组里的")
        #expect(admit(parent: helper, group: 900, responsible: 900) == .init(session: main, inherited: true), "离开了进程组的子进程")
        #expect(admit(parent: 700, group: 901, responsible: 700) == .init(session: main, inherited: false), "XPC 服务派生的")
        // launchd 代 App 启动的 XPC 服务（WebKit 的 WebContent 等）：只有负责进程是会话的
        #expect(admit(parent: 1, group: 900, responsible: main) == .init(session: main, inherited: false))
        #expect(admit(parent: 1, group: 900, responsible: 900) == nil)
    }

    @Test("拦截记录归属的判断：负责进程是会话主进程、但没继承盒子沙盒规则的不算")
    func attributionRule() {
        typealias Identity = ViolationMonitor.Parser.Identity
        let main: pid_t = 500
        func belongs(_ identity: Identity, name: String = "x", main: pid_t? = main) -> Bool {
            ViolationMonitor.Parser.belongs(identity, main: main, boxPrefix: "/box/", loggedName: name, processNames: ["Helper"])
        }
        // 系统代 App 启动的 XPC 服务：父进程是 launchd、自己一个进程组，负责进程是 App；它报告的拒绝来自它自己的沙盒
        let webContent = Identity(path: "/System/Library/Frameworks/WebKit.framework/XPCServices/WebContent", parent: 1,
                                  group: 900, responsible: main)
        #expect(!belongs(webContent))
        #expect(belongs(Identity(path: "/usr/bin/touch", parent: 1, group: main, responsible: 900)), "会话进程组里的")
        #expect(belongs(Identity(path: "/usr/bin/touch", parent: main, group: 901)), "会话主进程直接派生、离开了进程组的")
        #expect(belongs(Identity(path: "/box/App/S.app/Contents/MacOS/S", parent: 1, group: 1)), "盒子里的程序")
        #expect(belongs(Identity(path: nil, guardSession: main)), "守卫记下的成员，已退出")
        #expect(!belongs(Identity(path: "/usr/bin/touch", parent: 1, group: 900, guardSession: 999)), "别的会话的成员")
        #expect(belongs(Identity(path: nil), name: "Helper"), "已退出：按名字")
        #expect(!belongs(Identity(path: nil), name: "touch"))
        #expect(!belongs(Identity(path: "/usr/bin/touch", parent: 1, group: main), main: nil), "还不知道会话主进程")
    }

    @Test("解释器运行的脚本：给出参数原样，不解析符号链接；-c 这类没有脚本文件")
    func scriptArgument() async throws {
        let script = root.appending(path: "s.sh")
        try AppPaths.ensure(root)
        try "sleep 3\ntrue\n".write(to: script, atomically: true, encoding: .utf8) // 最后一条不是 sleep：sh 可能直接 exec 最后一条
        // 临时目录本身经过符号链接（/var → /private/var），给出的必须还是原样
        let unresolved = script.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        let file = try ChildProcess.spawn("/bin/sh", [unresolved])
        let inline = try ChildProcess.spawn("/bin/sh", ["-c", "sleep 3; true", unresolved])
        defer { [file, inline].forEach { $0.signal(SIGKILL) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(ProcessTable.scriptArgument(of: file.pid, executable: "/bin/sh") == unresolved)
        #expect(ProcessTable.scriptArgument(of: inline.pid, executable: "/bin/sh") == nil)
        #expect(ProcessTable.scriptArgument(of: file.pid, executable: "/bin/sleep") == nil, "不是解释器")
    }

    @Test("系统日志：几毫秒就结束的系统工具（touch）的拒绝记录也归盒子", .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
    func shortLivedToolAttribution() async throws {
        let (paths, config) = try makeBox()
        // 内核会丢弃一部分拒绝报告（全局限流），多试几次
        var received: BlockEvent?
        for _ in 0..<3 where received == nil {
            let session = SessionPID()
            let events = await ViolationMonitor.events(boxPrefix: FileOps.realPath(paths.url), processNames: [], session: session)
            let name = "dev.macboxtest.\(UUID().uuidString).plist"
            let target = "\(AppPaths.realHome.path)/Library/LaunchAgents/\(name)"
            defer { try? FileManager.default.removeItem(atPath: target) }
            let waiting = Task { () -> BlockEvent? in
                for await event in events where event.target.hasSuffix(name) { return event }
                return nil
            }
            var options = ChildProcess.Options()
            options.environment["HOME"] = paths.home.path
            options.newProcessGroup = true
            options.disclaimResponsibility = true
            // touch 被拒绝后立刻退出，拦截记录到达时它早已不在：名字不在盒子里，也查不到它的进程信息
            let main = try ChildProcess.spawn("/usr/bin/sandbox-exec", [
                "-p", SandboxProfile.make(box: paths, config: config),
                "/bin/sh", "-c", "sleep 0.3; /usr/bin/touch '\(target)'; sleep 1",
            ], options: options)
            EscapeGuard.shared.register(session: main.pid)
            session.set(main.pid)
            let timeout = Task {
                try await Task.sleep(for: .seconds(6))
                waiting.cancel()
            }
            received = await waiting.value
            timeout.cancel()
            main.signal(SIGKILL)
            _ = await main.waitForExit()
            EscapeGuard.shared.unregister(session: main.pid)
        }
        #expect(received?.kind == .autostart)
    }

    @Test("系统日志：多个订阅共用一个 log 进程；盒子派生的系统程序的拒绝记录归盒子，本机同名进程的不归")
    func sharedLogStream() async throws {
        let (paths, config) = try makeBox()
        func logProcesses() async -> Int {
            let children = (try? await Shell.run("/usr/bin/pgrep", ["-P", "\(getpid())", "-x", "log"]))?.output ?? ""
            return children.split(separator: "\n").count
        }
        let session = SessionPID()
        let mine = await ViolationMonitor.events(boxPrefix: FileOps.realPath(paths.url), processNames: [], session: session)
        // 另一个盒子，主程序也叫 sh：名字对得上，但进程不是它的
        let other = await ViolationMonitor.events(boxPrefix: "/nonexistent/", processNames: ["sh", "bash", "zsh"],
                                                  session: SessionPID())
        #expect(await logProcesses() == 1)
        let otherTargets = Mutex<[String]>([])
        let otherReader = Task {
            for await event in other { otherTargets.withLock { $0.append(event.target) } }
        }
        defer { otherReader.cancel() }

        // 内核会丢弃一部分拒绝报告（全局限流），多试几次
        var received: BlockEvent?
        for _ in 0..<3 where received == nil {
            let name = "dev.macboxtest.\(UUID().uuidString).plist"
            let target = "\(AppPaths.realHome.path)/Library/LaunchAgents/\(name)"
            defer { try? FileManager.default.removeItem(atPath: target) }
            let waiting = Task { () -> BlockEvent? in
                for await event in mine where event.target.hasSuffix(name) { return event }
                return nil
            }
            // 会话主进程启动的系统程序（名字不在盒子的可执行文件里、也不在盒子里）去写 LaunchAgents，写完还活着
            var options = ChildProcess.Options()
            options.environment["HOME"] = paths.home.path
            options.newProcessGroup = true
            options.disclaimResponsibility = true
            let main = try ChildProcess.spawn("/usr/bin/sandbox-exec", [
                "-p", SandboxProfile.make(box: paths, config: config),
                "/bin/sh", "-c", "/bin/sh -c \"echo x > '\(target)'; sleep 4\"; true",
            ], options: options)
            session.set(main.pid)
            let timeout = Task {
                try await Task.sleep(for: .seconds(6))
                waiting.cancel()
            }
            received = await waiting.value
            timeout.cancel()
            main.signal(SIGKILL)
            if received != nil {
                try await Task.sleep(for: .milliseconds(300)) // 同一行日志同时分发给每个订阅
                #expect(!otherTargets.withLock { $0 }.contains { $0.hasSuffix(name) }, "按名字把别人的拒绝记录算给了另一个盒子")
            }
        }
        #expect(received?.kind == .autostart)
    }

    @Test("拦截记录归属：活着的进程看位置和所属会话，名字只用来认已经退出的进程")
    func attribution() async throws {
        let (paths, config) = try makeBox()
        let stub = paths.appDirectory.appending(path: "S.app/Contents/MacOS/stub")
        try await TestStub.install(at: stub)
        let session = SessionPID()
        func parser(installer: Bool = false) -> ViolationMonitor.Parser {
            ViolationMonitor.Parser(boxPrefix: FileOps.realPath(paths.url) + "/", processNames: ["sleep", "Helper"],
                                    installer: installer, home: FileOps.realPath(AppPaths.realHome), session: session)
        }
        func message(_ name: String, _ pid: pid_t, _ operation: String = "file-write-create",
                     _ target: String = "/Library/LaunchAgents/dev.macboxtest.plist") -> ViolationMonitor.Parser.Message {
            ViolationMonitor.Parser.Message(process: name, pid: pid, operation: operation, target: target)
        }

        // 本机一个同名的进程：活着、不在盒子里、不属于会话
        let outsider = try ChildProcess.spawn("/bin/sleep", ["5"])
        // 盒子里的程序
        let inBox = try ChildProcess.spawn(stub.path, ["inbox", "0", "5000"])
        // 会话：主进程启动一个系统程序
        var options = ChildProcess.Options()
        options.newProcessGroup = true
        options.disclaimResponsibility = true
        let main = try ChildProcess.spawn("/usr/bin/sandbox-exec", [
            "-p", SandboxProfile.make(box: paths, config: config), "/bin/sh", "-c", "/bin/sleep 5; true",
        ], options: options)
        defer { [outsider, inBox, main].forEach { $0.signal(SIGKILL) } }
        session.set(main.pid)
        #expect(await eventually { ProcessTable.pids(inGroup: main.pid).count == 2 })
        let tool = try #require(ProcessTable.pids(inGroup: main.pid).first { $0 != main.pid })
        let exited = try ChildProcess.spawn("/usr/bin/true", [])
        _ = await exited.waitForExit()

        #expect(parser().event(from: message("sleep", outsider.pid)) == nil, "本机同名进程")
        #expect(parser().event(from: message("stub", inBox.pid))?.kind == .autostart)
        #expect(parser().event(from: message("curl", tool))?.kind == .autostart, "会话派生的系统程序")
        #expect(parser().event(from: message("sh", main.pid)) != nil)
        #expect(parser().event(from: message("Helper", exited.pid)) != nil, "已退出：按名字")
        #expect(parser().event(from: message("Helpers", exited.pid)) == nil)
        // 安装器调用 hdiutil 挂载被挡：由系统的 diskimages-helper 报告，只算给安装器
        let mount = message("diskimages-helper", outsider.pid, "mach-lookup", "com.apple.DiskArbitration.diskarbitrationd")
        #expect(parser(installer: true).event(from: mount)?.kind == .diskMount)
        #expect(parser().event(from: mount) == nil)
    }
}
