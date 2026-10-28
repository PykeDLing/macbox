import Darwin
import Foundation
import Testing
@testable import MacBox

/// 另一个进程里的锁：`locker <锁文件> <ready 文件> <拿着多少毫秒>`。拿到锁后把 pid 写进 ready 文件，
/// 拿着锁等一会儿再退出（0 毫秒就是试一下拿不拿得到）；拿不到以 1 退出。不改锁文件的内容
nonisolated private enum TestLocker {
    private static let source = """
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/file.h>
    #include <unistd.h>
    int main(int argc, char **argv) {
      if (argc < 4) return 2;
      int fd = open(argv[1], O_RDWR | O_CREAT, 0600);
      if (fd < 0) return 3;
      if (flock(fd, LOCK_EX | LOCK_NB) != 0) return 1;
      FILE *f = fopen(argv[2], "w");
      if (f) { fprintf(f, "%d", getpid()); fclose(f); }
      usleep(atoi(argv[3]) * 1000);
      return 0;
    }
    """

    private static let compiled = Task { try await compileC(source, name: "locker") }

    /// 拿着 directory 里的引擎锁，直到被结束（最多 30 秒）
    static func hold(in directory: URL) async throws -> ChildProcess {
        let ready = directory.appending(path: "locker-ready")
        let child = try ChildProcess.spawn(try await compiled.value.path,
                                           [directory.appending(path: EngineLock.fileName).path, ready.path, "30000"])
        #expect(await eventually(.seconds(5)) { FileManager.default.fileExists(atPath: ready.path) }, "另一个进程没拿到锁")
        return child
    }

    /// 另一个进程此刻拿不拿得到 directory 里的引擎锁
    static func canAcquire(in directory: URL) async throws -> Bool {
        let child = try ChildProcess.spawn(try await compiled.value.path,
                                           [directory.appending(path: EngineLock.fileName).path, "/dev/null", "0"])
        let status = await child.waitForExit()
        #expect(status == 0 || status == 1, "试锁的程序出错了：\(status)")
        return status == 0
    }
}

private func makeTemporaryDirectory() throws -> URL {
    try AppPaths.ensure(FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-lock-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory))
}

/// 把“谁拿着锁”写进锁文件（另一个进程是测试用的小程序，不会写）
private func writeHolder(_ holder: EngineLock.Holder, in directory: URL) throws {
    try JSONEncoder().encode(holder).write(to: directory.appending(path: EngineLock.fileName))
}

@Suite("引擎锁", .serialized)
struct EngineLockTests {
    @Test("另一个进程拿着锁时拿不到，读得出是谁拿着；它被强制结束后马上拿得到")
    func heldByAnotherProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileOps.removeTree(directory) }
        let other = EngineLock.Holder(pid: 4242, path: "/Applications/MacBox.app", version: "9.9")
        try writeHolder(other, in: directory)
        let child = try await TestLocker.hold(in: directory)

        guard case .heldByOther(let holder) = try EngineLock.acquire(in: directory) else {
            Issue.record("另一个进程拿着锁，这里却拿到了")
            kill(child.pid, SIGKILL)
            return
        }
        #expect(holder == other)

        // 被强制结束（像崩溃一样）：内核释放它的锁，不留过期的锁
        kill(child.pid, SIGKILL)
        _ = await child.waitForExit()
        guard case .acquired(let lock) = try EngineLock.acquire(in: directory) else {
            Issue.record("拿着锁的进程已经结束，还是拿不到")
            return
        }
        let written = try JSONDecoder().decode(EngineLock.Holder.self, from: Data(contentsOf: lock.url))
        #expect(written.pid == getpid(), "拿到锁后没有写上自己")
    }

    @Test("拿到的锁别的进程拿不到；同一个进程再拿，得到的是同一把")
    func heldByThisProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileOps.removeTree(directory) }
        guard case .acquired(let first) = try EngineLock.acquire(in: directory),
              case .acquired(let second) = try EngineLock.acquire(in: directory) else {
            Issue.record("同一个进程第二次拿锁被自己挡住了")
            return
        }
        #expect(first === second)
        #expect(!(try await TestLocker.canAcquire(in: directory)))
    }

    @Test("锁的描述符不会被子进程继承：MacBox 结束后，还在运行的子进程不会占着锁")
    func notInheritedByChildren() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileOps.removeTree(directory) }
        guard case .acquired(let lock) = try EngineLock.acquire(in: directory) else {
            Issue.record("拿不到锁")
            return
        }
        #expect(fcntl(lock.descriptor, F_GETFD) & FD_CLOEXEC != 0)

        // 不经由 ChildProcess（它本来就只传 0/1/2），用最普通的 posix_spawn 启动：靠的只能是锁自己的 O_CLOEXEC
        var pid: pid_t = 0
        let words = ["/bin/sleep", "30"]
        let arguments = words.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, nil) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        // 相当于 MacBox 结束了（这个目录只有这个测试用，登记里留下一把关掉的锁不要紧）
        close(lock.descriptor)
        #expect(try await TestLocker.canAcquire(in: directory), "子进程继承了锁")
    }

    @Test("Holder 只有是 App 时才有 App 包的位置")
    func holderAppURL() {
        #expect(EngineLock.Holder(pid: 1, path: "/Applications/MacBox.app", version: nil).appURL?.path == "/Applications/MacBox.app")
        #expect(EngineLock.Holder(pid: 1, path: "/usr/local/bin/macbox", version: nil).appURL == nil)
    }
}

/// 另一个 MacBox 管理着盒子时，BoxStore 什么都不碰。要用 MacBox 的数据目录，只在设置了 MACBOX_DATA_ROOT 时运行
@Suite("引擎锁：BoxStore", .serialized, .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
@MainActor
struct EngineLockStoreTests {
    @Test("拿不到锁时不读盒子、不做收尾、不启动守卫：盒子里正在运行的程序留着，添加、打开请求都不处理")
    func managedElsewhere() async throws {
        // 守卫要是还开着（别的测试留下的），会把下面不在沙盒里的程序当成逃逸结束，这个测试就说明不了什么
        EscapeGuard.shared.stop()
        let lockDirectory = try makeTemporaryDirectory()
        defer { try? FileOps.removeTree(lockDirectory) }
        let other = EngineLock.Holder(pid: 4242, path: "/Applications/MacBox.app", version: "9.9")
        try writeHolder(other, in: lockDirectory)
        let locker = try await TestLocker.hold(in: lockDirectory)
        defer { kill(locker.pid, SIGKILL) }

        // 一个正在运行的盒子程序，像是另一个 MacBox 打开的。没有 box.json：读了盒子的话，会出现在读不出的盒子里
        let box = AppPaths.boxes.appending(path: "\(UUID().uuidString).box", directoryHint: .isDirectory)
        defer { try? FileOps.removeTree(box) }
        let stub = box.appending(path: "App/stub")
        try await TestStub.install(at: stub)
        var options = ChildProcess.Options()
        options.environment["STUB_DIR"] = box.path
        let running = try ChildProcess.spawn(stub.path, ["running", "0", "20000"], options: options)
        defer { kill(running.pid, SIGKILL) }
        #expect(await eventually { readPID(box.appending(path: "running")) == running.pid })

        let store = BoxStore(lockDirectory: lockDirectory)
        store.start()
        await store.ready()
        #expect(store.ownership == .otherProcess(other))
        #expect(store.boxes.isEmpty)
        #expect(store.brokenBoxes.isEmpty)

        let before = Set(FileOps.contents(of: AppPaths.boxes))
        await store.importItems([stub])
        store.handle(URL(string: "macbox://open/\(UUID().uuidString)")!)
        #expect(store.importError == nil)
        #expect(store.alerts.isEmpty, "没读盒子，不能说启动器对应的应用不在了")
        #expect(Set(FileOps.contents(of: AppPaths.boxes)) == before, "添加了应用")

        // 收尾第一步就会结束它，守卫每 50ms 一轮：等一会儿还在，才说明都没做
        try await Task.sleep(for: .seconds(1))
        #expect(isRunning(running.pid), "另一个 MacBox 打开的程序被结束了")
    }
}
