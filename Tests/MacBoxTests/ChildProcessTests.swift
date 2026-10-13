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
