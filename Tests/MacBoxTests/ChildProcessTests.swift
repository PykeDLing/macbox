import Foundation
import Testing
@testable import MacBox

@Suite("子进程")
struct ChildProcessTests {
    @Test("两路输出都超过管道缓冲区时不会死锁")
    func largeOutput() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero; head -c 200000 /dev/zero >&2"])
        #expect(result.outputData.count == 3_000_000)
        #expect(result.errorData.count == 200_000)
    }

    @Test("一个读取长期等待输出时，其他命令照常完成")
    func readersDoNotBlockEachOther() async throws {
        // 相当于运行中的应用对应的 log stream：一直不输出
        var options = ChildProcess.Options()
        options.output = .pipe
        let idle = try ChildProcess.spawn("/bin/sleep", ["30"], options: options)
        let reader = Task { await idle.standardOutput.collect() }
        defer { idle.signal(SIGKILL); reader.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        let clock = ContinuousClock()
        for _ in 0..<5 {
            let start = clock.now
            try await Shell.run("/usr/bin/true", [])
            #expect(clock.now - start < .seconds(2))
        }
    }

    @Test("子进程不继承 MacBox 的其他描述符")
    func noDescriptorLeak() async throws {
        // 一个“正在进行中”的命令持有的管道
        let pipe = Pipe()
        let child = try ChildProcess.spawn("/bin/sleep", ["2"])
        try pipe.fileHandleForWriting.close()
        let clock = ContinuousClock(), start = clock.now
        _ = try pipe.fileHandleForReading.readToEnd()
        #expect(clock.now - start < .milliseconds(500), "子进程持有了管道写端")
        child.signal(SIGKILL)
        _ = await child.waitForExit()
    }

    @Test("标准输入、退出码、错误输出")
    func basics() async throws {
        #expect(try await Shell.run("/bin/cat", [], input: "你好").output == "你好")
        let failed = try await Shell.execute("/bin/sh", ["-c", "echo boom >&2; exit 3"])
        #expect(failed.status == 3 && failed.error == "boom\n")
        await #expect(throws: MacBoxError.self) { try await Shell.run("/usr/bin/false", []) }
    }

    @Test("对方不读标准输入就退出时，MacBox 不会因 SIGPIPE 退出")
    func inputToExitedProcess() async throws {
        let result = try await Shell.execute("/usr/bin/true", [], input: String(repeating: "x", count: 1 << 20))
        #expect(result.status == 0)
    }

    @Test("立即退出的进程也能等到；可以多处同时等待")
    func immediateExit() async throws {
        let child = try ChildProcess.spawn("/usr/bin/true", [])
        async let a = child.waitForExit()
        async let b = child.waitForExit()
        #expect(await (a, b) == (0, 0))
        #expect(child.hasExited)
    }

    @Test("被信号结束时退出码为 128 + 信号")
    func signalExit() async throws {
        let child = try ChildProcess.spawn("/bin/sleep", ["10"])
        child.signal(SIGTERM)
        #expect(await child.waitForExit() == 128 + SIGTERM)
    }

    @Test("组长退出后，发给进程组的信号仍能到达组里留下的进程")
    func signalReachesGroupAfterLeaderExit() async throws {
        var options = ChildProcess.Options()
        options.newProcessGroup = true
        options.output = .pipe
        let leader = try ChildProcess.spawn("/bin/sh", ["-c", "/bin/sleep 30 >/dev/null 2>&1 & echo $!"], options: options)
        var lines = leader.standardOutput.lines().makeAsyncIterator()
        let member = try #require(await lines.next().flatMap { pid_t($0) })
        _ = await leader.waitForExit()
        #expect(isRunning(member))

        leader.signal(SIGKILL)
        #expect(await eventually { !isRunning(member) }, "组长已退出，组里的进程没收到信号")
        if isRunning(member) { kill(member, SIGKILL) }
    }

    /// 内核在子进程变成僵尸之前就发出退出事件，那一刻的 WNOHANG 回收会落空，而退出事件只有一次。
    /// 并发大量启动时才容易碰上（修复前约一半的运行会留下回收不了的僵尸进程，等它的地方永远等下去）
    @Test("并发大量启动的短命进程都能等到退出", .timeLimit(.minutes(2)))
    func reapUnderConcurrency() async throws {
        let width = 64, perWorker = 100
        let missed = await withTaskGroup(of: [pid_t].self) { group in
            for worker in 0..<width {
                group.addTask {
                    var missed: [pid_t] = []
                    for index in 0..<perWorker {
                        var options = ChildProcess.Options()
                        if (worker + index) % 2 == 0 {
                            options.output = .pipe
                            options.error = .pipe
                        }
                        guard let child = try? ChildProcess.spawn("/usr/bin/true", [], options: options) else { continue }
                        let deadline = ContinuousClock.now + .seconds(3)
                        while !child.hasExited, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
                        if !child.hasExited { missed.append(child.pid) }
                    }
                    return missed
                }
            }
            var all: [pid_t] = []
            for await missed in group { all += missed }
            return all
        }
        #expect(missed.isEmpty, "没有回收的进程：\(missed)")
    }

    @Test("任务取消时结束子进程")
    func cancellation() async throws {
        let task = Task { try await Shell.execute("/bin/sleep", ["10"]) }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock(), start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("按行切分")
    func lines() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        for chunk in ["a\nb", "c\n\nd"] { continuation.yield(Data(chunk.utf8)) }
        continuation.finish()
        var lines: [String] = []
        for await line in stream.lines() { lines.append(line) }
        #expect(lines == ["a", "bc", "", "d"])
    }
}
