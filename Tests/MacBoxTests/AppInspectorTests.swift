import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MacBox

/// App 信息、在线安装器识别、偏好设置域前缀、图标。只在临时目录里造 App 包，
/// 读本机「应用程序」文件夹也只读 Info.plist，不运行、不登记任何东西
@Suite("读取 App")
final class AppInspectorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    func directory(_ name: String = "dir") throws -> URL {
        let url = root.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writePlist(_ plist: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    /// 最小的 App 包；executable 为 nil 时 Info.plist 里不写 CFBundleExecutable，可执行文件按包名放
    @discardableResult
    func makeApp(_ url: URL, id: String, executable: String? = "main", info extra: [String: Any] = [:]) throws -> URL {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0"]
        if let executable { info["CFBundleExecutable"] = executable }
        info.merge(extra) { $1 }
        try writePlist(info, to: url.appending(path: "Contents/Info.plist"))
        let binary = url.appending(path: "Contents/MacOS/\(executable ?? url.deletingPathExtension().lastPathComponent)")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 信息

    @Test("同一路径上的 App 被换掉后读到新的标识符和可执行文件，不受 Bundle 缓存影响")
    func infoAfterReplacementAtSamePath() throws {
        let box = try directory("box")
        let app = box.appending(path: "App/Foo.app")
        try makeApp(app, id: "dev.macboxtest.foo.installer", executable: "FooInstaller")
        #expect(try AppInspector.info(of: app).executable.lastPathComponent == "FooInstaller")
        // 别处（旧的 info、图标）已经让 Bundle 缓存了这个路径
        #expect(Bundle(url: app)?.bundleIdentifier == "dev.macboxtest.foo.installer")

        // 和接手安装包时一样：新的 App 先放在 App.new，再换到原来的位置
        let staging = box.appending(path: "App.new")
        try makeApp(staging.appending(path: "Foo.app"), id: "dev.macboxtest.foo.real", executable: "Foo")
        try FileManager.default.moveItem(at: box.appending(path: "App"), to: box.appending(path: "App.old"))
        try FileManager.default.moveItem(at: staging, to: box.appending(path: "App"))
        try FileManager.default.removeItem(at: box.appending(path: "App.old"))

        let info = try AppInspector.info(of: app)
        #expect(info.bundleIdentifier == "dev.macboxtest.foo.real")
        #expect(info.executable.lastPathComponent == "Foo")
        #expect(FileManager.default.fileExists(atPath: info.executable.path))
    }

    @Test("名字：本地化的 InfoPlist.strings / InfoPlist.loctable 优先，其次 Info.plist，最后是文件名")
    func displayName() throws {
        let base = try directory()
        // 只有一种语言有 InfoPlist 本地化；另一种语言的 .lproj 里只有别的 .strings，不算
        let localized = try makeApp(base.appending(path: "Localized.app"), id: "dev.macboxtest.l10n",
                                    info: ["CFBundleName": "Plain"])
        let resources = localized.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources.appending(path: "zz.lproj"), withIntermediateDirectories: true)
        try "\"Other\" = \"x\";".write(to: resources.appending(path: "zz.lproj/Localizable.strings"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: resources.appending(path: "zh-Hans.lproj"), withIntermediateDirectories: true)
        try "/* 注释 */\n\"CFBundleDisplayName\" = \"本地化名\";\n"
            .write(to: resources.appending(path: "zh-Hans.lproj/InfoPlist.strings"), atomically: true, encoding: .utf16)
        #expect(try AppInspector.info(of: localized).name == "本地化名")

        let table = try makeApp(base.appending(path: "Table.app"), id: "dev.macboxtest.loctable")
        try writePlist(["LocProvenance": [:], "zh-Hans": ["CFBundleDisplayName": "表里的名字"]],
                       to: table.appending(path: "Contents/Resources/InfoPlist.loctable"))
        #expect(try AppInspector.info(of: table).name == "表里的名字")

        let plain = try makeApp(base.appending(path: "Plain.app"), id: "dev.macboxtest.plain",
                                info: ["CFBundleDisplayName": "  ", "CFBundleName": "Plain Name"])
        #expect(try AppInspector.info(of: plain).name == "Plain Name", "空白的显示名不算")
        let bare = try makeApp(base.appending(path: "Bare Name.app"), id: "dev.macboxtest.bare")
        #expect(try AppInspector.info(of: bare).name == "Bare Name")
    }

    @Test("可执行文件：没写 CFBundleExecutable 时按包名找；文件不存在、带路径的都不认")
    func executable() throws {
        let base = try directory()
        let implicit = try makeApp(base.appending(path: "Implicit.app"), id: "dev.macboxtest.implicit", executable: nil)
        #expect(try AppInspector.info(of: implicit).executable.lastPathComponent == "Implicit")

        let missing = try makeApp(base.appending(path: "Missing.app"), id: "dev.macboxtest.missing")
        try FileManager.default.removeItem(at: missing.appending(path: "Contents/MacOS/main"))
        #expect(throws: MacBoxError.self) { try AppInspector.info(of: missing) }

        let escaping = try makeApp(base.appending(path: "Escaping.app"), id: "dev.macboxtest.escaping",
                                   info: ["CFBundleExecutable": "../MacOS/main"])
        #expect(throws: MacBoxError.self) { try AppInspector.info(of: escaping) }
        #expect(throws: MacBoxError.self) { try AppInspector.info(of: base.appending(path: "Nothing.app")) }
    }

    // MARK: - 在线安装器

    func appInfo(name: String, file: String? = nil, id: String = "dev.macboxtest.app", at directory: URL? = nil) -> AppInfo {
        let url = (directory ?? root.appending(path: "nonexistent")).appending(path: "\(file ?? name).app")
        return AppInfo(url: url, name: name, bundleIdentifier: id, version: nil, executable: url.appending(path: "Contents/MacOS/main"))
    }

    @Test("在线安装器：按完整的词认，卸载程序、普通的下载工具不算",
          arguments: [
            ("Install Spotify", nil, "dev.macboxtest.spotify", true),
            ("WeChatSetup", nil, "dev.macboxtest.wechat", true),
            ("Quark Installer", nil, "dev.macboxtest.quark", true),
            ("WPSInstaller", nil, "dev.macboxtest.wps", true),
            ("QQ安装器", nil, "dev.macboxtest.qq", true),
            ("微信安装助手", nil, "dev.macboxtest.wx", true),
            ("夸克网盘", "QuarkCloudDrive", "com.quark.clouddrive.installer", true),
            ("Foo", "Foo-Setup", "dev.macboxtest.foo", true),
            ("4K Video Downloader+", nil, "com.openmedia.4kvideodownloaderplus", false),
            ("JDownloader 2", nil, "org.jdownloader.launcher", false),
            ("App Cleaner & Uninstaller", nil, "com.nektony.App-Cleaner-SII", false),
            ("Uninstaller", nil, "dev.macboxtest.uninstaller", false),
            ("UnInstall Helper", nil, "dev.macboxtest.helper", false),
            ("Un-Installer", nil, "dev.macboxtest.helper", false),
            ("软件卸载工具", nil, "dev.macboxtest.remover", false),
            ("Reinstaller", nil, "dev.macboxtest.reinstaller", false),
            ("Setapp", nil, "com.setapp.DesktopClient", false),
            ("Downie", nil, "com.charliemonroe.Downie-4", false),
          ] as [(String, String?, String, Bool)])
    func installerNames(name: String, file: String?, id: String, expected: Bool) {
        #expect(AppInspector.looksLikeInstaller(appInfo(name: name, file: file, id: id)) == expected)
    }

    @Test("Chromium 系：按这台 Mac 上实际的几种 App 包认，加上 --no-sandbox；单独用 Crashpad 的普通 App 不算",
          arguments: [
            (["Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler"], true), // Electron（抖音、Claude）
            (["Chromium Embedded Framework.framework", "NeteaseMusic Helper (Renderer).app"], true), // CEF（网易云音乐）
            (["QQ Helper (Renderer).app", "QQ Helper.app"], true), // QQ 只有这个
            (["Microsoft Edge Framework.framework/Versions/A/Helpers/msedge_crashpad_handler"], true),
            (["Codex Framework.framework/Versions/A/Helpers/browser_crashpad_handler"], true), // ChatGPT
            (["Sentry.framework", "crashpad_handler"], false), // 微信：单独用 Crashpad
            (["Sparkle.framework/Versions/B/Updater.app"], false),
            ([], false),
          ] as [([String], Bool)])
    func chromium(items: [String], expected: Bool) throws {
        let app = try directory("chromium").appending(path: "App.app")
        for item in ["Contents/MacOS"] + items.map({ "Contents/Frameworks/" + $0 }) {
            try AppPaths.ensure(app.appending(path: item))
        }
        #expect(AppInspector.isChromium(app) == expected)
        #expect(AppInspector.launchArguments(for: app) == (expected ? ["--no-sandbox"] : []))
    }

    @Test("名字里有 Downloader 的：只有像个安装器桩程序（很小、没有 Frameworks）时才算")
    func downloaderStub() throws {
        let base = try directory()
        let stub = try makeApp(base.appending(path: "Foo Downloader.app"), id: "dev.macboxtest.stub")
        #expect(AppInspector.looksLikeInstaller(appInfo(name: "Foo Downloader", at: base)))

        let full = try makeApp(base.appending(path: "Bar Downloader.app"), id: "dev.macboxtest.full")
        try FileManager.default.createDirectory(at: full.appending(path: "Contents/Frameworks/Qt.framework"),
                                                withIntermediateDirectories: true)
        #expect(!AppInspector.looksLikeInstaller(appInfo(name: "Bar Downloader", at: base)))
        #expect(FileManager.default.fileExists(atPath: stub.path))
    }

    @Test("拆词：驼峰、数字、汉字交界")
    func words() {
        #expect(AppInspector.words(in: "WeChatSetup") == ["we", "chat", "setup"])
        #expect(AppInspector.words(in: "WPSInstaller") == ["wps", "installer"])
        #expect(AppInspector.words(in: "QQ安装器2") == ["qq", "安装器", "2"])
        #expect(AppInspector.words(in: "App Cleaner & Uninstaller") == ["app", "cleaner", "uninstaller"])
    }

    // MARK: - 偏好设置域

    @Test("偏好设置域前缀：同厂商的其他产品、共用前缀的大厂都不放宽",
          arguments: [
            ("com.google.Chrome.canary", ["com.google.Chrome"], ["com.google.Chrome.canary"]),
            ("com.google.Chrome.canary", [], ["com.google.Chrome.canary"]),
            ("com.microsoft.edgemac.Beta", [], ["com.microsoft.edgemac.Beta"]),
            ("com.apple.dt.Xcode", [], ["com.apple.dt.Xcode"]),
            ("com.jetbrains.intellij.ce", ["com.jetbrains.intellij"], ["com.jetbrains.intellij.ce"]),
            ("com.quark.clouddrive", [], ["com.quark.clouddrive"]),
            ("com.quark.clouddrive.mac", [], ["com.quark.clouddrive"]),
            // 同一个 App 的本机副本不算“其他 App”
            ("com.quark.clouddrive.mac", ["com.quark.clouddrive.mac"], ["com.quark.clouddrive"]),
            // 放宽后会盖住本机另一个 App，或落在它之下，都不放宽
            ("com.quark.clouddrive.mac", ["com.quark.clouddrive.player"], ["com.quark.clouddrive.mac"]),
            ("com.quark.clouddrive.mac", ["com.quark.clouddrive"], ["com.quark.clouddrive.mac"]),
            ("dev.macboxtest.a.b", ["dev.macboxtest"], ["dev.macboxtest.a.b"]),
            ("com.foo", [], ["com.foo"]),
            // jp.co.、cn.com.、uk.co. 这类两段后缀：厂商是前三段，五段以上才放宽，放宽到前四段。
            // 佳能的打印、扫描工具装在 /Library/Printers 等查不到的地方，整个厂商不放宽
            ("jp.co.canon.ij.scanutility", [], ["jp.co.canon.ij.scanutility"]),
            ("jp.co.example.scanner", [], ["jp.co.example.scanner"]),
            ("jp.co.example.scan.utility", [], ["jp.co.example.scan"]),
            ("cn.com.foo.bar.app", [], ["cn.com.foo.bar"]),
            ("cn.com.foo.bar.app", ["cn.com.foo.bar.player"], ["cn.com.foo.bar.app"]),
            ("uk.co.foo.app", [], ["uk.co.foo.app"]),
            // 反写时顺序搞反的 foo.com.cn → com.cn.foo
            ("com.cn.foo.app", [], ["com.cn.foo.app"]),
            ("com.cn.foo.bar.app", [], ["com.cn.foo.bar"]),
            // 两个字母的厂商名（jd.com）不是国家顶级域，照常放宽
            ("com.jd.mall.mac", [], ["com.jd.mall"]),
          ] as [(String, Set<String>, [String])])
    func preferencePrefixes(identifier: String, installed: Set<String>, expected: [String]) throws {
        let app = try makeApp(try directory().appending(path: "A.app"), id: identifier)
        #expect(AppInspector.preferencePrefixes(for: app, identifier: identifier, installed: installed) == expected)
    }

    @Test("偏好设置域前缀：包里同一厂商的登录项、Helpers、XPC 服务、扩展、内嵌 App 也借出，第三方组件不借")
    func nestedPreferencePrefixes() throws {
        let app = try makeApp(try directory().appending(path: "Vendor.app"), id: "dev.macboxtest.vendor.app")
        let contents = app.appending(path: "Contents")
        try makeApp(contents.appending(path: "Library/LoginItems/Login.app"), id: "dev.macboxtest.login")
        try makeApp(contents.appending(path: "Helpers/Agent.app"), id: "dev.macboxtest.agent")
        try writePlist(["CFBundleIdentifier": "dev.macboxtest.vendor.app.xpc"],
                       to: contents.appending(path: "XPCServices/Service.xpc/Contents/Info.plist"))
        try writePlist(["CFBundleIdentifier": "dev.macboxtest.share"],
                       to: contents.appending(path: "PlugIns/Share.appex/Contents/Info.plist"))
        try writePlist(["CFBundleIdentifier": "org.sparkle-project.Downloader"],
                       to: contents.appending(path: "XPCServices/Downloader.xpc/Contents/Info.plist"))
        try makeApp(contents.appending(path: "Frameworks/Electron Framework.framework/Versions/A/Helpers/chrome.app"),
                    id: "com.github.Electron.helper")
        try FileManager.default.createSymbolicLink(
            atPath: contents.appending(path: "Frameworks/Electron Framework.framework/Versions/Current").path, withDestinationPath: "A")
        // 内嵌 App 里的登录项（第二层）
        let embedded = try makeApp(contents.appending(path: "Resources/Embedded.app"), id: "dev.macboxtest.embedded")
        try makeApp(embedded.appending(path: "Contents/Library/LoginItems/Deep.app"), id: "dev.macboxtest.deep")

        let nested = AppInspector.nestedBundleIdentifiers(in: app)
        for id in ["dev.macboxtest.login", "dev.macboxtest.agent", "dev.macboxtest.vendor.app.xpc", "dev.macboxtest.share",
                   "org.sparkle-project.Downloader", "com.github.Electron.helper", "dev.macboxtest.embedded", "dev.macboxtest.deep"] {
            #expect(nested.contains(id), "\(id)")
        }

        // 本机装着同厂商的另一个 App：主标识符不放宽，与它重名的部件也不借
        let prefixes = AppInspector.preferencePrefixes(for: app, identifier: "dev.macboxtest.vendor.app",
                                                       installed: ["dev.macboxtest.vendor.other", "dev.macboxtest.agent"])
        #expect(prefixes == ["dev.macboxtest.vendor.app", "dev.macboxtest.login", "dev.macboxtest.share",
                             "dev.macboxtest.embedded", "dev.macboxtest.deep"])
        // 没有冲突时放宽到前三段，被它盖住的部件不再单列
        let widened = AppInspector.preferencePrefixes(for: app, identifier: "dev.macboxtest.vendor.app", installed: [])
        #expect(widened.first == "dev.macboxtest.vendor" && !widened.contains("dev.macboxtest.vendor.app.xpc"))
    }

    @Test("偏好设置域前缀：两段后缀（cn.com.）下按前三段认厂商，别家的部件、只有厂商根的部件都不借")
    func secondLevelSuffixVendors() throws {
        let app = try makeApp(try directory().appending(path: "Foo.app"), id: "cn.com.foo.bar.app")
        let contents = app.appending(path: "Contents")
        try makeApp(contents.appending(path: "Library/LoginItems/Agent.app"), id: "cn.com.foo.agent")
        try makeApp(contents.appending(path: "Helpers/Other.app"), id: "cn.com.other.helper")
        try writePlist(["CFBundleIdentifier": "cn.com.foo"], to: contents.appending(path: "XPCServices/Root.xpc/Contents/Info.plist"))
        #expect(AppInspector.preferencePrefixes(for: app, identifier: "cn.com.foo.bar.app", installed: [])
                == ["cn.com.foo.bar", "cn.com.foo.agent"])
    }

    @Test("本机安装的 App：读「应用程序」顶层和其中文件夹里的 Info.plist")
    func installedApplications() throws {
        let base = try directory("Applications")
        try makeApp(base.appending(path: "Top.app"), id: "dev.macboxtest.top")
        try makeApp(base.appending(path: "Vendor/Inner.app"), id: "dev.macboxtest.inner")
        try makeApp(base.appending(path: "Vendor/Deeper/Hidden.app"), id: "dev.macboxtest.too-deep")
        #expect(AppInspector.installedApplicationIdentifiers(in: [base]) == ["dev.macboxtest.top", "dev.macboxtest.inner"])

        let system = AppInspector.installedApplicationIdentifiers()
        #expect(system.contains("com.apple.calculator") && system.contains("com.apple.Terminal"))
        #expect(AppInspector.preferencePrefixes(for: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
                                                identifier: "com.apple.calculator") == ["com.apple.calculator"])
    }

    // MARK: - 图标

    static let calculatorResources = URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/Resources")

    /// 画成 32×32 的像素，用来比较两个图标是不是同一个
    func pixels(_ image: NSImage) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.bitmapData.map { Data(bytes: $0, count: bitmap.bytesPerRow * 32) }
    }

    @Test("图标：从 .icns 或 Assets.car 读，没有时用通用图标；都不登记进 LaunchServices")
    func icons() async throws {
        let base = try directory("icons")
        let icns = Self.calculatorResources.appending(path: "AppIcon.icns")
        let car = Self.calculatorResources.appending(path: "Assets.car")
        try #require(FileManager.default.fileExists(atPath: icns.path) && FileManager.default.fileExists(atPath: car.path))

        let withIcns = try makeApp(base.appending(path: "Icns.app"), id: "dev.macboxtest.icon-icns",
                                   info: ["CFBundleIconFile": "AppIcon", "CFBundleURLTypes": [["CFBundleURLSchemes": ["dev-macboxtest-icon"]]]])
        try FileManager.default.createDirectory(at: withIcns.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: icns, to: withIcns.appending(path: "Contents/Resources/AppIcon.icns"))

        let withCar = try makeApp(base.appending(path: "Car.app"), id: "dev.macboxtest.icon-car", info: ["CFBundleIconName": "AppIcon"])
        try FileManager.default.createDirectory(at: withCar.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: car, to: withCar.appending(path: "Contents/Resources/Assets.car"))

        let plain = try makeApp(base.appending(path: "Plain.app"), id: "dev.macboxtest.icon-none",
                                info: ["CFBundleIconFile": "Missing"])

        let generic = try #require(pixels(NSWorkspace.shared.icon(for: .applicationBundle)))
        let fromIcns = AppIcon.load(withIcns)
        #expect(fromIcns.representations.count == NSImage(contentsOf: icns)?.representations.count)
        #expect(pixels(fromIcns) != generic)
        #expect(pixels(AppIcon.load(withCar)) != generic)
        #expect(pixels(AppIcon.load(plain)) == generic)

        let dump = try await Shell.run(Shell.lsregister, ["-dump"]).output
        for app in [withIcns, withCar, plain] {
            #expect(!dump.contains(app.path) && !dump.contains(FileOps.realPath(app)), "\(app.lastPathComponent) 被登记了")
            _ = try? await Shell.run(Shell.lsregister, ["-u", app.path])
        }
    }
}
