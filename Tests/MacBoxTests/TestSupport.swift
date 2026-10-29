import Foundation
import Testing
@testable import MacBox

/// 进程还在运行（僵尸进程不算）
nonisolated func isRunning(_ pid: pid_t) -> Bool {
    guard let lineage = ProcessTable.lineage(of: pid) else { return false }
    return !lineage.isZombie
}

/// 等条件成立，最多 timeout
nonisolated func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

nonisolated func readPID(_ url: URL) -> pid_t? {
    (try? String(contentsOf: url, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// 一个可以放进盒子的 Mach-O 小程序（系统自带的程序复制出来会被启动约束结束）：
/// `stub <名字> <先等毫秒> <后等毫秒> [子进程参数…]`：把自己的 pid 写进 $STUB_DIR/<名字>，等一会儿，
/// 有子进程参数时用同一个程序启动子进程，再等一会儿后退出
nonisolated enum TestStub {
    private static let source = """
    #include <spawn.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    extern char **environ;
    int main(int argc, char **argv) {
      if (argc < 4) return 2;
      const char *dir = getenv("STUB_DIR");
      if (dir) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/%s", dir, argv[1]);
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "%d", getpid()); fclose(f); }
      }
      usleep(atoi(argv[2]) * 1000);
      if (argc > 4) {
        pid_t child;
        char **args = calloc(argc, sizeof(char *));
        args[0] = argv[0];
        for (int i = 4; i < argc; i++) args[i - 3] = argv[i];
        posix_spawn(&child, argv[0], NULL, NULL, args, environ);
      }
      usleep(atoi(argv[3]) * 1000);
      return 0;
    }
    """

    private static let compiled = Task { try await compileC(source, name: "stub") }

    /// 编译好的程序复制到 destination（目录不存在时创建）
    static func install(at destination: URL) async throws {
        try await installCompiled(compiled.value, at: destination)
    }
}

/// 离开会话进程组的盒子辅助程序（像调用过 setsid、以 detached 方式启动的辅助程序）：
/// 启动后 fork，父进程立即退出，子进程 setsid 后等待；收到 SIGTERM 时在 $TMPDIR 里留下 detached-term 再退出。
/// 最多运行 30 秒，测试失败时也不会一直留着
nonisolated enum TestDetachedHelper {
    private static let source = """
    #include <fcntl.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    static char marker[4096];
    static void term(int signal) { close(open(marker, O_CREAT | O_WRONLY, 0644)); _exit(0); }
    int main(void) {
      const char *dir = getenv("TMPDIR");
      snprintf(marker, sizeof(marker), "%s/detached-term", dir ? dir : "/nonexistent");
      if (fork() != 0) return 0;
      setsid();
      signal(SIGTERM, term);
      for (int i = 0; i < 300; i++) usleep(100000);
      return 0;
    }
    """

    private static let compiled = Task { try await compileC(source, name: "detached") }

    static func install(at destination: URL) async throws {
        try await installCompiled(compiled.value, at: destination)
    }
}

/// 主程序是编译好的空程序、按给定权限做 ad-hoc 签名的 App 包，用来测签名里的权限（见 AppInspector.entitlements）。
/// 只造不运行：用苹果沙盒的 App 一运行，系统就会在你真实的 ~/Library/Containers 里给它建容器
nonisolated enum SignedTestApp {
    private static let compiled = Task { try await compileC("int main(void) { return 0; }\n", name: "signed") }

    /// entitlements 为 nil 时签名不带权限；signed 为 false 时不签名
    static func make(at app: URL, identifier: String, entitlements: [String: Any]?, signed: Bool = true) async throws {
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "main", "CFBundleName": "Signed",
                                   "CFBundlePackageType": "APPL"]
        try AppPaths.ensure(app.appending(path: "Contents"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try installCompiled(try await compiled.value, at: app.appending(path: "Contents/MacOS/main"))
        guard signed else { return }
        let arguments = ["-s", "-", "-f"]
        if let entitlements {
            let file = app.deletingLastPathComponent().appending(path: "\(UUID().uuidString).entitlements")
            defer { try? FileManager.default.removeItem(at: file) }
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
            try await Shell.run("/usr/bin/codesign", arguments + ["--entitlements", file.path, app.path])
        } else {
            try await Shell.run("/usr/bin/codesign", arguments + [app.path])
        }
    }
}

/// 把一段 C 源码编译到临时目录里
nonisolated func compileC(_ source: String, name: String) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(name)-\(UUID().uuidString)")
    try AppPaths.ensure(folder)
    let output = folder.appending(path: name)
    try await Shell.run("/usr/bin/cc", ["-x", "c", "-o", output.path, "-"], input: source)
    return output
}

/// 编译好的程序复制到 destination（目录不存在时创建）
nonisolated func installCompiled(_ program: URL, at destination: URL) throws {
    try AppPaths.ensure(destination.deletingLastPathComponent())
    try FileOps.removeIfExists(destination)
    try FileManager.default.copyItem(at: program, to: destination)
}

/// 隔离会话的测试要一个能解锁的盒子钥匙串。security create-keychain 会临时改动你的钥匙串搜索列表，
/// 几处同时创建可能互相覆盖、留下测试的钥匙串，所以整个测试进程只创建一个（在临时目录里），各个盒子复制它
nonisolated enum TestKeychain {
    private static let template = Task { () throws -> BoxPaths in
        let paths = BoxPaths(url: FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-keychain-\(UUID().uuidString)",
                                                                                    directoryHint: .isDirectory))
        try await BoxKeychain.prepare(paths)
        await removeTestKeychainsFromSearchList()
        return paths
    }

    static func install(into paths: BoxPaths) async throws {
        let template = try await template.value
        try AppPaths.ensure(paths.keychains)
        try FileOps.clone(template.boxKeychain, to: paths.boxKeychain)
        try FileOps.clone(template.keychainPassword, to: paths.keychainPassword)
    }

    /// 和其他同时创建钥匙串的测试交错时，搜索列表里可能留下测试的钥匙串：只去掉这些，其余原样保留
    private static func removeTestKeychainsFromSearchList() async {
        guard let output = try? await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output else { return }
        let list = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
        let kept = list.filter { !$0.contains("/MacBoxTests-") }
        guard kept.count != list.count, !kept.isEmpty else { return }
        _ = try? await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user", "-s"] + kept)
    }
}

/// 一个主程序是 shell 脚本的假 App
nonisolated func makeFakeApp(at app: URL, identifier: String, script: String) throws {
    let macOS = app.appending(path: "Contents/MacOS")
    try AppPaths.ensure(macOS)
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "main", "CFBundleName": "Fake",
                               "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appending(path: "Contents/Info.plist"))
    let main = macOS.appending(path: "main")
    try script.write(to: main, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path)
}
