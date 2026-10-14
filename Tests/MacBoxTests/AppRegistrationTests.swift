import Foundation
import Testing
@testable import MacBox

/// 撤销系统（LaunchServices）对盒子里 App 的登记。测试会真的登记、撤销临时目录里的小 App（dev.macboxtest.*），
/// 结束时把这个目录下的登记全部撤销，不影响别的 App
@Suite("App 登记", .serialized)
struct AppRegistrationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-LS-\(UUID().uuidString)")

    /// 一个 App 包，里面嵌着辅助程序和登录项（像网易有道翻译、夸克网盘那样）
    func makeApp(_ name: String) throws -> URL {
        let app = root.appending(path: "\(name).app")
        for (bundle, id) in [(app, "outer"), (app.appending(path: "Contents/Helpers/Helper.app"), "helper"),
                             (app.appending(path: "Contents/Library/LoginItems/Login.app"), "login")] {
            let macOS = bundle.appending(path: "Contents/MacOS")
            try AppPaths.ensure(macOS)
            let info: [String: Any] = ["CFBundleIdentifier": "dev.macboxtest.ls.\(name).\(id)", "CFBundleExecutable": "x",
                                       "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appending(path: "Contents/Info.plist"))
            try "#!/bin/sh\n".write(to: macOS.appending(path: "x"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appending(path: "x").path)
        }
        return app
    }

    func registered() async throws -> [String] {
        let dump = try await Shell.execute(Shell.lsregister, ["-dump"])
        return AppRegistration.registeredPaths(in: dump.output, under: root)
    }

    func cleanUp() async {
        await AppRegistration.unregisterAll(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("从 lsregister -dump 的输出里取出某目录下的登记：去掉末尾的编号、重复的只算一次、其他目录的不算")
    func parseDump() {
        let root = URL(fileURLWithPath: "/Users/x/Library/Application Support/MacBox/Boxes")
        let dump = """
        bundle id:                  1234
        path:                       /Users/x/Library/Application Support/MacBox/Boxes/A.box/App/X.app (0x1a2b)
        name:                       X
        path:                       /Users/x/Library/Application Support/MacBox/Boxes/A.box/App/X.app/Contents/Helpers/H.app (0x1a2c)
        path:                       /Users/x/Library/Application Support/MacBox/Boxes/A.box/App/X.app (0x1a2b)
        path:                       /Applications/Safari.app (0x0042)
        path:                       /Users/x/Library/Application Support/MacBox/BoxesOther/Y.app (0x0043)
        """
        #expect(AppRegistration.registeredPaths(in: dump, under: root) == [
            "/Users/x/Library/Application Support/MacBox/Boxes/A.box/App/X.app",
            "/Users/x/Library/Application Support/MacBox/Boxes/A.box/App/X.app/Contents/Helpers/H.app",
        ])
    }

    @Test("撤销 App 的登记时连同包里嵌套的辅助程序、登录项一起撤销（只用 -u 会留下它们）")
    func unregisterIncludesNestedApps() async throws {
        let app = try makeApp("Nested")
        defer { await cleanUp() }
        _ = try await Shell.execute(Shell.lsregister, ["-f", "-R", app.path])
        #expect(try await registered().count == 3)

        await AppRegistration.unregister(app)
        #expect(try await registered().isEmpty, "包里嵌套的 App 还登记着")
    }

    @Test("启动时的清理：文件夹已经不在了的登记（换掉的 App.new、删掉的盒子）也撤销得掉")
    func unregisterAllRemovesStaleEntries() async throws {
        let app = try makeApp("Stale")
        defer { await cleanUp() }
        _ = try await Shell.execute(Shell.lsregister, ["-f", "-R", app.path])
        // 像删除盒子、换掉 App.new 那样把文件夹移走：登记还按旧路径留着
        try FileManager.default.moveItem(at: app, to: root.appending(path: "Moved.app"))
        _ = try await Shell.execute(Shell.lsregister, ["-f", "-R", root.appending(path: "Moved.app").path])
        try FileManager.default.removeItem(at: root.appending(path: "Moved.app"))
        #expect(try await registered().count >= 3)

        await AppRegistration.unregisterAll(under: root)
        #expect(try await registered().isEmpty)
    }
}
