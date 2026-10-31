import Foundation
import Testing
@testable import MacBox

/// 只在临时目录里打包、挂载、展开（挂载的都是测试自己做的映像），不碰 MacBox 的数据目录。
/// 依次执行：多个映像同时挂载时 hdiutil 偶尔会报“资源暂时不可用”，也便于检查有没有没卸载的映像
@Suite("取出 App", .serialized)
final class PackageExtractorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    func directory(_ name: String = "dir") throws -> URL {
        let url = root.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeApp(in directory: URL, name: String, id: String, padding: Int = 4096) throws -> URL {
        let app = directory.appending(path: "\(name).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
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
        let source = try directory("source")
        _ = try makeApp(in: source, name: "Demo", id: "dev.macboxtest.demo", padding: 200_000)
        _ = try makeApp(in: source, name: "Uninstall Demo", id: "dev.macboxtest.uninstall", padding: 400_000)
        return source
    }

    func output() -> URL { root.appending(path: "out-\(UUID().uuidString)") }

    /// 只打包不安装。没有 payload 时是只有脚本的安装包（卸载程序常见的样子）
    func makePkg(_ name: String, in directory: URL, payload: URL?, scripts: URL? = nil,
                 installLocation: String = "/Applications") async throws -> URL {
        let pkg = directory.appending(path: "\(name).pkg")
        var arguments = ["--quiet", "--identifier", "dev.macboxtest.pkg.\(UUID().uuidString.prefix(8))", "--version", "1"]
        if let payload {
            arguments += ["--root", payload.path, "--install-location", installLocation]
        } else {
            arguments += ["--nopayload"]
        }
        if let scripts { arguments += ["--scripts", scripts.path] }
        try await Shell.run("/usr/bin/pkgbuild", arguments + [pkg.path])
        return pkg
    }

    /// 装着一个 App 的安装包
    func makeAppPkg(_ name: String, app: String, in directory: URL) async throws -> URL {
        let payload = try self.directory("payload")
        _ = try makeApp(in: payload, name: app, id: "dev.macboxtest.\(app.lowercased())")
        return try await makePkg(name, in: directory, payload: payload)
    }

    /// 产品归档（productbuild 做的分发包）：组件包套在外层安装包里，展开后 App 在 <组件>.pkg/Payload 下。
    /// Zoom、Chrome、Office 等厂商的安装包和在线安装器下载的安装包多半是这种
    func makeProductArchive(_ name: String, app: String, in directory: URL) async throws -> URL {
        let component = try await makeAppPkg("component", app: app, in: try self.directory("component"))
        let product = directory.appending(path: "\(name).pkg")
        try await Shell.run("/usr/bin/productbuild", ["--quiet", "--package", component.path, product.path])
        return product
    }

    /// 卸载包：比安装包大，里面也有个 App（清理工具），只看体积或排序就会选错
    func makeUninstallerPkg(_ name: String, in directory: URL) async throws -> URL {
        let payload = try self.directory("uninstaller")
        let app = try makeApp(in: payload, name: "Cleanup", id: "dev.macboxtest.cleanup", padding: 0)
        try randomData(1_000_000).write(to: app.appending(path: "Contents/padding"))
        return try await makePkg(name, in: directory, payload: payload)
    }

    /// 只装驱动（Library/Audio/Plug-Ins/HAL 下的 .driver），没有 App 的安装包
    func makeDriverPkg(in directory: URL) async throws -> URL {
        let payload = try self.directory("driver")
        let driver = payload.appending(path: "Library/Audio/Plug-Ins/HAL/MacBoxTestDriver.driver/Contents")
        try FileManager.default.createDirectory(at: driver, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.macboxtest.driver"], format: .xml, options: 0)
            .write(to: driver.appending(path: "Info.plist"))
        return try await makePkg("Driver", in: directory, payload: payload, installLocation: "/")
    }

    func makeDmg(of folder: URL, name: String = "demo") async throws -> URL {
        let dmg = try directory("dmg").appending(path: "\(name).dmg")
        try await Shell.run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "APFS", "-srcfolder", folder.path, dmg.path])
        return dmg
    }

    /// 和浏览器下载的一样：Foo.dmg → Foo.dmg.zip，压缩包里顶层就是 Foo.dmg
    func makeZip(of item: URL) async throws -> URL {
        let zip = try directory("zip").appending(path: "\(item.lastPathComponent).zip")
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", item.path, zip.path])
        return zip
    }

    /// 测试目录下的映像，以及（套在压缩包里、展开到别处的）指定文件名的映像，都已卸载
    func noImagesAttached(named name: String? = nil) async -> Bool {
        let prefix = FileOps.realPath(root) + "/"
        return await !DiskImage.attached().contains { image in
            let url = URL(fileURLWithPath: image.imagePath)
            return FileOps.realPath(url).hasPrefix(prefix) || url.lastPathComponent == name
        }
    }

    func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    func expectNoSymlinks(in directory: URL) {
        for item in FileOps.contents(of: directory) { #expect(!FileOps.isSymlink(item), "\(item.path)") }
    }

    // MARK: - 基本格式

    @Test(".app：复制并读出信息")
    func app() async throws {
        let app = try makeApp(in: try directory(), name: "Demo", id: "dev.macboxtest.demo.app")
        let extracted = try await PackageExtractor.extractApp(from: app, into: output())
        let info = try AppInspector.info(of: extracted.app)
        #expect(info.bundleIdentifier == "dev.macboxtest.demo.app" && info.version == "1.2.3")
        #expect(AppInspector.preferencePrefix(for: info.bundleIdentifier) == "dev.macboxtest.demo")
    }

    @Test(".zip：跳过卸载程序")
    func zip() async throws {
        let zip = try await makeZip(of: try makeSource())
        #expect(try await PackageExtractor.extractApp(from: zip, into: output()).app.lastPathComponent == "Demo.app")
    }

    @Test(".dmg：挂载、取出、卸载", arguments: [false, true])
    func dmg(nested: Bool) async throws {
        var source = try makeSource()
        if nested {
            let wrapper = try directory("wrapper")
            try FileManager.default.moveItem(at: source, to: wrapper.appending(path: "Folder"))
            source = wrapper
        }
        let dmg = try await makeDmg(of: source)
        #expect(try await PackageExtractor.extractApp(from: dmg, into: output()).app.lastPathComponent == "Demo.app")
        #expect(await noImagesAttached())
    }

    @Test(".pkg：只取 App，安装脚本不执行但会标记")
    func pkg() async throws {
        let payload = try directory("payload"), scripts = try directory("scripts")
        _ = try makeApp(in: payload, name: "PkgApp", id: "dev.macboxtest.pkgapp")
        let marker = root.appending(path: "SHOULD_NOT_EXIST")
        let script = scripts.appending(path: "postinstall")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pkg = try await makePkg("demo", in: try directory(), payload: payload, scripts: scripts)
        let extracted = try await PackageExtractor.extractApp(from: pkg, into: output())
        #expect(extracted.app.lastPathComponent == "PkgApp.app")
        #expect(extracted.issues.contains { $0.code == .installerScriptsSkipped })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("产品归档（productbuild）：单独的、装在 dmg 里的、装在 zip 里的都能取出 App", arguments: ["pkg", "dmg", "zip"])
    func productArchive(container: String) async throws {
        let source = try directory("source")
        var package = try await makeProductArchive("Product", app: "Prod", in: source)
        if container == "dmg" { package = try await makeDmg(of: source) }
        if container == "zip" { package = try await makeZip(of: package) }
        let extracted = try await PackageExtractor.extractApp(from: package, into: output())
        #expect(extracted.app.lastPathComponent == "Prod.app")
        #expect(try AppInspector.info(of: extracted.app).bundleIdentifier == "dev.macboxtest.prod")
        #expect(await noImagesAttached())
    }

    @Test("不支持的类型报错")
    func unsupported() async {
        await #expect(throws: MacBoxError.self) {
            try await PackageExtractor.extractApp(from: self.root.appending(path: "a.tar"), into: self.output())
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

    // MARK: - 套娃

    @Test("dmg 子文件夹里的安装包：Installer/PkgApp.pkg")
    func pkgInDiskImageFolder() async throws {
        let source = try directory("source")
        let installer = source.appending(path: "Installer")
        try FileManager.default.createDirectory(at: installer, withIntermediateDirectories: true)
        _ = try await makeAppPkg("PkgApp", app: "PkgApp", in: installer)
        let dmg = try await makeDmg(of: source)
        #expect(try await PackageExtractor.extractApp(from: dmg, into: output()).app.lastPathComponent == "PkgApp.app")
        #expect(await noImagesAttached())
    }

    @Test("zip 里的 dmg（Inner.dmg.zip），用完卸载")
    func diskImageInZip() async throws {
        let source = try directory("source")
        _ = try makeApp(in: source, name: "Inner", id: "dev.macboxtest.inner")
        let name = "Inner-\(UUID().uuidString).dmg"
        let dmg = try await makeDmg(of: source, name: (name as NSString).deletingPathExtension)
        let zip = try await makeZip(of: dmg)
        #expect(try await PackageExtractor.extractApp(from: zip, into: output()).app.lastPathComponent == "Inner.app")
        #expect(await noImagesAttached(named: name))
    }

    @Test("zip 里的 pkg（PkgApp.pkg.zip）")
    func pkgInZip() async throws {
        let pkg = try await makeAppPkg("PkgApp", app: "PkgApp", in: try directory())
        let zip = try await makeZip(of: pkg)
        #expect(try await PackageExtractor.extractApp(from: zip, into: output()).app.lastPathComponent == "PkgApp.app")
    }

    @Test("zip 套 zip：三层还取，四层不再往里走", arguments: [3, 4])
    func nestedZips(levels: Int) async throws {
        let source = try directory("source")
        _ = try makeApp(in: source, name: "Deep", id: "dev.macboxtest.deep")
        var item = try await makeZip(of: source.appending(path: "Deep.app"))
        for _ in 1..<levels { item = try await makeZip(of: item) }
        if levels <= 3 {
            #expect(try await PackageExtractor.extractApp(from: item, into: output()).app.lastPathComponent == "Deep.app")
        } else {
            await #expect(throws: MacBoxError.self) { try await PackageExtractor.extractApp(from: item, into: self.output()) }
        }
    }

    // MARK: - 多个安装包

    /// “Foo Uninstaller.pkg”“Uninstall Zoom.pkg”按名字排在安装包前面（空格排在“.”前）
    @Test("dmg 里有安装包和卸载包：卸载包排在前面、体积更大也不用它",
          arguments: [("Foo.pkg", "Foo Uninstaller.pkg"), ("Zoom.pkg", "Uninstall Zoom.pkg"), ("Install Foo.pkg", "Uninstall Foo.pkg")])
    func uninstallerPackageSkipped(installer: String, uninstaller: String) async throws {
        let source = try directory("source")
        let main = try await makeAppPkg((installer as NSString).deletingPathExtension, app: "Foo", in: source)
        let other = try await makeUninstallerPkg((uninstaller as NSString).deletingPathExtension, in: source)
        #expect(FileOps.allocatedSize(of: other) > FileOps.allocatedSize(of: main))
        let dmg = try await makeDmg(of: source)
        #expect(try await PackageExtractor.extractApp(from: dmg, into: output()).app.lastPathComponent == "Foo.app")
        #expect(await noImagesAttached())
    }

    @Test("dmg 里有多个安装包：先试最大的，取不出 App 再试下一个")
    func packagesTriedInTurn() async throws {
        let source = try directory("source")
        _ = try await makeAppPkg("Foo", app: "Foo", in: source)
        // 更大、按名字也排在前面，但只装资源、没有 App 的组件包
        let payload = try directory("extras")
        try randomData(1_000_000).write(to: payload.appending(path: "data.bin"))
        let extras = try await makePkg("Extras", in: source, payload: payload, installLocation: "/Library/Application Support/Foo")
        #expect(FileOps.allocatedSize(of: extras) > FileOps.allocatedSize(of: source.appending(path: "Foo.pkg")))
        let dmg = try await makeDmg(of: source)
        #expect(try await PackageExtractor.extractApp(from: dmg, into: output()).app.lastPathComponent == "Foo.app")
        #expect(await noImagesAttached())
    }

    // MARK: - 没找到

    static let notFoundInDiskImage = "磁盘映像里没有找到 App 或安装包"

    @Test("dmg 里只有无关的压缩包（说明文档、坏的压缩包）：报磁盘映像里没找到，不报里面压缩包的错")
    func unrelatedArchivesInDiskImage() async throws {
        let source = try directory("source")
        let docs = try directory("Documentation")
        try "readme".write(to: docs.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: try await makeZip(of: docs), to: source.appending(path: "Documentation.zip"))
        try Data("not a zip".utf8).write(to: source.appending(path: "Broken.zip"))
        let dmg = try await makeDmg(of: source)
        let error = await #expect(throws: MacBoxError.self) { try await PackageExtractor.extractApp(from: dmg, into: self.output()) }
        #expect(error?.message == Self.notFoundInDiskImage)
        #expect(await noImagesAttached())
    }

    @Test("dmg 里的安装包展开失败：报磁盘映像里没找到，附上是哪个安装包、为什么")
    func brokenPackageInDiskImage() async throws {
        let source = try directory("source")
        try Data("not a package".utf8).write(to: source.appending(path: "Broken.pkg"))
        let dmg = try await makeDmg(of: source)
        let error = await #expect(throws: MacBoxError.self) { try await PackageExtractor.extractApp(from: dmg, into: self.output()) }
        let message = try #require(error?.message)
        #expect(message.hasPrefix(Self.notFoundInDiskImage) && message.contains("Broken.pkg") && message.contains("pkgutil"), "\(message)")
        #expect(await noImagesAttached())
    }

    // MARK: - 只能用虚拟 Mac

    @Test("只有驱动的安装包，单独的或装在 dmg 里的，都报 NeedsVirtualMac", arguments: [false, true])
    func driverOnlyPackage(inDiskImage: Bool) async throws {
        let source = try directory("source")
        var package = try await makeDriverPkg(in: source)
        if inDiskImage { package = try await makeDmg(of: source) }
        await #expect(throws: PackageExtractor.NeedsVirtualMac.self) {
            try await PackageExtractor.extractApp(from: package, into: self.output())
        }
        let error = PackageExtractor.NeedsVirtualMac()
        #expect(error.localizedDescription == error.message && error.message.contains("虚拟 Mac"))
        #expect(await noImagesAttached())
    }

    // MARK: - 符号链接

    @Test("dmg 顶层的 App 是指向卷内的符号链接：复制真实的 App，名字照旧", arguments: ["Payload/Foo.app", ".payload/Foo.app"])
    func symlinkedAppInsideImage(target: String) async throws {
        let source = try directory("source")
        let real = source.appending(path: target).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        _ = try makeApp(in: real, name: "Foo", id: "dev.macboxtest.symlinked", padding: 0)
        // 链接名和真实名不同，确认用的是看到的名字
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "Foo Link.app").path, withDestinationPath: target)
        let dmg = try await makeDmg(of: source)
        let out = output()
        let extracted = try await PackageExtractor.extractApp(from: dmg, into: out)
        #expect(extracted.app.lastPathComponent == "Foo Link.app")
        #expect(!FileOps.isSymlink(extracted.app))
        #expect(try AppInspector.info(of: extracted.app).bundleIdentifier == "dev.macboxtest.symlinked")
        expectNoSymlinks(in: out)
        #expect(await noImagesAttached())
    }

    @Test("dmg 里指到卷外的 App 链接不要：不能把本机的 App 当成盒子里的")
    func symlinkLeavingImageRejected() async throws {
        let source = try directory("source")
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "Calc.app").path,
                                                   withDestinationPath: "/System/Applications/Calculator.app")
        let dmg = try await makeDmg(of: source)
        let out = output()
        await #expect(throws: MacBoxError.self) { try await PackageExtractor.extractApp(from: dmg, into: out) }
        #expect(FileOps.contents(of: out).isEmpty)
        #expect(await noImagesAttached())
    }

    @Test("zip 里指到外面的 App 链接不要，指向里面的照常取")
    func symlinksInZip() async throws {
        let source = try directory("source")
        let folder = source.appending(path: "Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "Calc.app").path,
                                                   withDestinationPath: "/System/Applications/Calculator.app")
        let zip = try await makeZip(of: folder)
        await #expect(throws: MacBoxError.self) { try await PackageExtractor.extractApp(from: zip, into: self.output()) }

        _ = try makeApp(in: folder.appending(path: "Payload"), name: "Real", id: "dev.macboxtest.real")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "Real.app").path, withDestinationPath: "Payload/Real.app")
        let zip2 = try await makeZip(of: folder)
        let extracted = try await PackageExtractor.extractApp(from: zip2, into: output())
        #expect(extracted.app.lastPathComponent == "Real.app" && !FileOps.isSymlink(extracted.app))
    }

    @Test("直接拖进来的 App 是符号链接：复制它指向的 App")
    func symlinkedAppDropped() async throws {
        let real = try makeApp(in: try directory(), name: "Real", id: "dev.macboxtest.dropped")
        let link = try directory("link").appending(path: "Shown.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let extracted = try await PackageExtractor.extractApp(from: link, into: output())
        #expect(extracted.app.lastPathComponent == "Shown.app" && !FileOps.isSymlink(extracted.app))
        #expect(try AppInspector.info(of: extracted.app).bundleIdentifier == "dev.macboxtest.dropped")
    }

    // MARK: - 隔离标记

    func quarantine(_ url: URL) -> String? {
        PackageExtractor.quarantine(of: url).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 带一个只读文件的 App 的安装包（只读的项目要临时加写权限才能打标记）
    func makeQuarantineTestPkg() async throws -> URL {
        let payload = try directory("payload")
        let app = try makeApp(in: payload, name: "Marked", id: "dev.macboxtest.marked")
        let readOnly = app.appending(path: "Contents/Resources/readonly.txt")
        try FileManager.default.createDirectory(at: readOnly.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: readOnly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        return try await makePkg("Marked", in: try directory(), payload: payload)
    }

    func expectQuarantined(_ app: URL, as value: String) throws {
        for relative in ["", "Contents", "Contents/MacOS/main", "Contents/Info.plist", "Contents/Resources/readonly.txt"] {
            #expect(quarantine(relative.isEmpty ? app : app.appending(path: relative)) == value, "\(relative)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: app.appending(path: "Contents/Resources/readonly.txt").path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o444, "只读文件打完标记要恢复原来的权限")
    }

    @Test("带隔离标记的 pkg：取出的 App 补上同样的标记")
    func quarantineFromPackage() async throws {
        let pkg = try await makeQuarantineTestPkg()
        FileOps.markQuarantined(pkg)
        let value = try #require(quarantine(pkg))
        let extracted = try await PackageExtractor.extractApp(from: pkg, into: output())
        try expectQuarantined(extracted.app, as: value)
    }

    @Test("带隔离标记的 zip 里的 pkg：同样补上")
    func quarantineFromZippedPackage() async throws {
        let zip = try await makeZip(of: try await makeQuarantineTestPkg())
        FileOps.markQuarantined(zip)
        let extracted = try await PackageExtractor.extractApp(from: zip, into: output())
        #expect(quarantine(extracted.app) != nil)
        #expect(quarantine(extracted.app.appending(path: "Contents/MacOS/main")) != nil)
    }

    @Test("去掉隔离标记（通过公证后）：只读的文件也去掉，权限恢复原样")
    func clearQuarantine() async throws {
        let pkg = try await makeQuarantineTestPkg()
        FileOps.markQuarantined(pkg)
        let app = try await PackageExtractor.extractApp(from: pkg, into: output()).app
        try expectQuarantined(app, as: try #require(quarantine(pkg)))
        // 包里指向外面的符号链接：只处理链接本身，不能去改它指向的文件
        let outside = try directory("outside").appending(path: "target.txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        FileOps.markQuarantined(outside)
        try FileManager.default.createSymbolicLink(at: app.appending(path: "Contents/Resources/link.txt"), withDestinationURL: outside)

        PackageExtractor.clearQuarantine(app)
        var items = [app]
        let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL { items.append(item) }
        #expect(items.count > 5)
        for item in items { #expect(quarantine(item) == nil, "\(item.path)") }
        let mode = try FileManager.default.attributesOfItem(atPath: app.appending(path: "Contents/Resources/readonly.txt").path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o444, "去掉标记后要恢复原来的权限")
        #expect(quarantine(outside) != nil, "链接指向的包外文件不动")
    }

    @Test("没有隔离标记的 pkg：取出的 App 也不加")
    func noQuarantineFromCleanPackage() async throws {
        let pkg = try await makeQuarantineTestPkg()
        let extracted = try await PackageExtractor.extractApp(from: pkg, into: output())
        #expect(quarantine(extracted.app) == nil)
        #expect(quarantine(extracted.app.appending(path: "Contents/MacOS/main")) == nil)
    }

    // MARK: - 导入前检查

    @Test("导入前检查：存在的东西还要类型对得上，文件夹给出明确的说明")
    func checkSupportedKinds() throws {
        let base = try directory("kinds")
        func file(_ name: String) throws -> URL {
            let url = base.appending(path: name)
            try Data("x".utf8).write(to: url)
            return url
        }
        func folder(_ name: String) throws -> URL {
            let url = base.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func message(_ url: URL) -> String? {
            do {
                try PackageExtractor.checkSupported(url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        let isFolder = { (text: String?) in text?.contains("文件夹") == true || text?.contains("folder") == true }

        let app = try makeApp(in: base, name: "Good", id: "dev.macboxtest.good")
        let link = base.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        for ok in try [app, link, file("a.dmg"), file("b.zip"), file("c.pkg"), folder("Legacy.pkg"), folder("d.mpkg")] {
            #expect(message(ok) == nil, "\(ok.lastPathComponent)")
        }
        for name in ["Some Folder", "Folder.dmg", "Folder.zip"] {
            #expect(isFolder(message(try folder(name))), "\(name)")
        }
        for bad in try [file("Fake.app"), file("noext"), file("disk.iso")] {
            let text = message(bad)
            #expect(text != nil && !isFolder(text), "\(bad.lastPathComponent)")
        }
        let locked = try file("locked.dmg")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        #expect(message(locked) != nil, "没有读取权限")
        // 还不存在的只看扩展名
        #expect(message(base.appending(path: "missing.dmg")) == nil)
        #expect(message(base.appending(path: "missing.iso")) != nil)
    }
}
