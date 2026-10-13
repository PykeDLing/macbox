import Foundation
import Testing
@testable import MacBox

@Suite("取出 App")
struct PackageExtractorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    func makeApp(in directory: URL, name: String, id: String, padding: Int = 4096) throws -> URL {
        let app = directory.appending(path: "\(name).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try AppPaths.ensure(macOS)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": "main",
                                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try "#!/bin/sh\n".write(to: macOS.appending(path: "main"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appending(path: "main").path)
        try Data(count: padding).write(to: app.appending(path: "Contents/padding"))
        return app
    }

    /// 一个 App 加一个更大的卸载程序
    func makeSource() throws -> URL {
        let source = root.appending(path: "source-\(UUID().uuidString)")
        try AppPaths.ensure(source)
        _ = try makeApp(in: source, name: "Demo", id: "dev.macboxtest.demo", padding: 200_000)
        _ = try makeApp(in: source, name: "Uninstall Demo", id: "dev.macboxtest.uninstall", padding: 400_000)
        return source
    }

    func output() -> URL { root.appending(path: "out-\(UUID().uuidString)") }

    @Test(".app：复制并读出信息")
    func app() async throws {
        let app = try makeApp(in: root, name: "Demo", id: "dev.macboxtest.demo.app")
        let extracted = try await PackageExtractor.extractApp(from: app, into: output())
        let info = try AppInspector.info(of: extracted.app)
        #expect(info.bundleIdentifier == "dev.macboxtest.demo.app" && info.version == "1.2.3")
        #expect(AppInspector.preferencePrefix(for: info.bundleIdentifier) == "dev.macboxtest.demo")
    }

    @Test(".zip：跳过卸载程序")
    func zip() async throws {
        let zip = root.appending(path: "demo.zip")
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", try makeSource().path, zip.path])
        #expect(try await PackageExtractor.extractApp(from: zip, into: output()).app.lastPathComponent == "Demo.app")
    }

    @Test(".dmg：挂载、取出、卸载", .serialized, arguments: [false, true])
    func dmg(nested: Bool) async throws {
        var source = try makeSource()
        if nested {
            let wrapper = root.appending(path: "wrapper-\(UUID().uuidString)")
            try AppPaths.ensure(wrapper)
            try FileManager.default.moveItem(at: source, to: wrapper.appending(path: "Folder"))
            source = wrapper
        }
        let dmg = root.appending(path: "demo-\(UUID().uuidString).dmg")
        try await Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "APFS", "-srcfolder", source.path, dmg.path])
        #expect(try await PackageExtractor.extractApp(from: dmg, into: output()).app.lastPathComponent == "Demo.app")
        #expect(await DiskImage.attached(fromImagesUnder: FileOps.realPath(root)).isEmpty)
    }

    @Test(".pkg：只取 App，安装脚本不执行但会标记")
    func pkg() async throws {
        let payload = root.appending(path: "payload"), scripts = root.appending(path: "scripts")
        try AppPaths.ensure(payload)
        try AppPaths.ensure(scripts)
        _ = try makeApp(in: payload, name: "PkgApp", id: "dev.macboxtest.pkgapp")
        let marker = root.appending(path: "SHOULD_NOT_EXIST")
        let script = scripts.appending(path: "postinstall")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pkg = root.appending(path: "demo.pkg")
        try await Shell.run("/usr/bin/pkgbuild", ["--quiet", "--root", payload.path, "--scripts", scripts.path,
                                                  "--identifier", "dev.macboxtest.pkg", "--version", "1",
                                                  "--install-location", "/Applications", pkg.path])
        let extracted = try await PackageExtractor.extractApp(from: pkg, into: output())
        #expect(extracted.app.lastPathComponent == "PkgApp.app")
        #expect(extracted.issues.contains { $0.title == "安装脚本已跳过" })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("不支持的类型报错")
    func unsupported() async {
        await #expect(throws: MacBoxError.self) {
            try await PackageExtractor.extractApp(from: root.appending(path: "a.tar"), into: output())
        }
    }

    @Test("box.json：往返一致；缺少非可选字段的文件读不出（新增字段必须是可选类型）")
    func config() throws {
        let config = BoxConfig(id: UUID(), name: "名", bundleIdentifier: "a.b.c", appFolderName: "A.app")
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(BoxConfig.self, from: data) == config)
        var dictionary = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dictionary["resetOnQuit"] = nil
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BoxConfig.self, from: JSONSerialization.data(withJSONObject: dictionary))
        }
    }
}
