import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MacBox

/// 盒子数据的维护操作（还原点、清除数据、钥匙串），以及几处容易出错的匹配规则
@Suite("盒子数据")
@MainActor
struct BoxDataTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")

    func makeBox(prefix: String = "dev.macboxtest.data-\(UUID().uuidString.prefix(8))") throws -> Box {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        try AppPaths.ensure(paths.home)
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: prefix + ".app", appFolderName: "T.app")
        config.preferencePrefixes = [prefix]
        return Box(paths: paths, config: config)
    }

    func write(_ text: String, to url: URL) throws {
        try AppPaths.ensure(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test("还原点连同钥匙串密码一起保存：清除数据后还原，钥匙串和密码仍然配套")
    func restorePointKeepsKeychainPassword() async throws {
        let box = try makeBox()
        let paths = box.paths
        let file = paths.home.appending(path: "Documents/note.txt")
        try write("before", to: file)
        try write("password-1", to: paths.keychainPassword)

        try await box.createRestorePoint()
        try await box.clearData()
        #expect(read(file) == nil)
        // 盒子一辈子只用一个密码：清除数据不删它，之后新建的钥匙串沿用它（见 BoxKeychain）
        #expect(read(paths.keychainPassword) == "password-1")

        try await box.restoreRestorePoint()
        #expect(read(file) == "before")
        #expect(read(paths.keychainPassword) == "password-1")
        #expect(box.activity == .idle)
    }

    @Test("旧版还原点没有钥匙串密码：还原时保留现有的密码")
    func legacyRestorePointKeepsCurrentPassword() async throws {
        let box = try makeBox()
        let paths = box.paths
        try write("password-1", to: paths.keychainPassword)
        try await box.createRestorePoint()
        try FileManager.default.removeItem(at: paths.restorePoint.appending(path: paths.keychainPassword.lastPathComponent))

        try await box.restoreRestorePoint()
        #expect(read(paths.keychainPassword) == "password-1")
    }

    @Test("还原点里过时的借出日志不会被还原回来")
    func staleLeaseJournalIsNotRestored() async throws {
        let box = try makeBox()
        let paths = box.paths
        try await box.createRestorePoint()
        // 旧版 MacBox 在借出没收回时创建的还原点
        let saved = BoxPaths(url: paths.restorePoint)
        try write("{}", to: saved.leaseJournal)
        try AppPaths.ensure(saved.nativePrefsBackup)

        try await box.restoreRestorePoint()
        #expect(!FileManager.default.fileExists(atPath: paths.leaseJournal.path))
        #expect(!FileManager.default.fileExists(atPath: paths.nativePrefsBackup.path))
    }

    @Test("删除还原点：同时关闭自动还原")
    func deleteRestorePoint() async throws {
        let box = try makeBox()
        try await box.createRestorePoint()
        box.config.resetOnQuit = true
        #expect(box.restorePointDate != nil)

        try await box.deleteRestorePoint()
        #expect(box.restorePointDate == nil && !box.config.resetOnQuit && box.activity == .idle)
    }

    /// 用真实的 ~/Library/Preferences（借出就是在这里做的），域名只用测试专用的，结束时删除
    @Test("清除数据前先收回上次没收回的偏好设置，本机原来的设置不会丢")
    func clearDataSettlesOutstandingLease() async throws {
        let domain = "dev.macboxtest.settle-\(UUID().uuidString.prefix(8))"
        let system = AppPaths.realHome.appending(path: "Library/Preferences/\(domain)").path
        defer {
            // 和 PreferenceLease 一样：只用 defaults delete 的话，cfprefsd 之后会写回一个空 plist
            _ = try? await Shell.run("/usr/bin/defaults", ["delete", system])
            try? FileManager.default.removeItem(atPath: system + ".plist")
        }
        try await Shell.run("/usr/bin/defaults", ["write", system, "who", "native"])

        let box = try makeBox(prefix: domain)
        try AppPaths.ensure(box.paths.prefs)
        try PropertyListSerialization.data(fromPropertyList: ["who": "box"], format: .binary, options: 0)
            .write(to: box.paths.prefs.appending(path: "\(domain).plist"))
        // 借出后 MacBox “崩溃”：没有收回
        try await PreferenceLease(box: box.paths, prefixes: [domain]).checkIn()
        #expect(try await Shell.run("/usr/bin/defaults", ["read", system, "who"]).output == "box\n")

        try await box.clearData()
        #expect(try await Shell.run("/usr/bin/defaults", ["read", system, "who"]).output == "native\n")
        #expect(!PreferenceLease(box: box.paths, prefixes: [domain]).isOutstanding)
    }

    @Test("钥匙串和密码对不上、密码丢失时换一个新钥匙串，不会再也打不开；搜索列表不变")
    func keychainSelfHeals() async throws {
        func searchList() async throws -> String {
            try await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output
        }
        let before = try await searchList()
        let paths = try makeBox().paths

        try await BoxKeychain.prepare(paths)
        #expect(FileOps.isSymlink(paths.loginKeychainLink))

        try write("wrong", to: paths.keychainPassword)
        try await BoxKeychain.prepare(paths)
        try FileManager.default.removeItem(at: paths.keychainPassword)
        try await BoxKeychain.prepare(paths)

        let password = try #require(read(paths.keychainPassword))
        try await Shell.run("/usr/bin/security", ["unlock-keychain", "-p", password, paths.boxKeychain.path])
        let unusable = FileOps.contents(of: paths.keychains).filter { $0.lastPathComponent.hasPrefix("box-unusable") }
        #expect(unusable.count == 2, "旧钥匙串改名保留，不直接删除")
        #expect(try await searchList() == before)
    }

    // MARK: - 匹配规则

    @Test("0.4.0 及以前的 box.json：兼容性问题按中文标题认出代码，公证检查的来源从说明里拆出；两种语言都照常显示，存回去不丢旧字段")
    func legacyIssues() throws {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        defer { try? FileManager.default.removeItem(at: root) }
        // 旧版本写下的问题只有中文的标题和说明
        let old: [(title: String, detail: String, code: CompatibilityIssue.Code?, source: String?)] = [
            ("已通过 Apple 公证检查", "Developer ID Application: Example Ltd (ABCDE12345)", .notarized,
             "Developer ID Application: Example Ltd (ABCDE12345)"),
            ("已通过 Apple 公证检查", "来源已验证", .notarized, nil),
            ("未通过 Apple 公证检查", "Unnotarized Developer ID。打开时 macOS 会询问你是否信任它，请确认来源可靠。", .notNotarized,
             "Unnotarized Developer ID"),
            ("未通过 Apple 公证检查", "签名无效。打开时 macOS 会询问你是否信任它，请确认来源可靠。", .notNotarized, nil),
            ("需要管理员权限的辅助程序", "会以 root 身份在系统里安装常驻服务，本机隔离无法容纳。", .privilegedHelper, nil),
            ("系统级后台服务", "会注册开机即运行的系统服务。", .systemService, nil),
            ("系统扩展或内核扩展", "需要加载到系统内核或系统扩展框架中。", .systemExtension, nil),
            ("硬件或音频驱动", "驱动需要安装到系统目录。", .driver, nil),
            ("开机自启动", "自启动项会被阻止，只有你打开时它才运行。", .loginItem, nil),
            ("访达集成", "同步状态图标、右键菜单等访达扩展不可用。", .finderIntegration, nil),
            ("网络扩展", "VPN、代理等网络扩展需要系统级安装。", .networkExtension, nil),
            ("自带苹果沙盒", "在 MacBox 中它改由 MacBox 的沙盒约束，数据存进盒子；请经由 MacBox 打开它。", .appSandbox, nil),
            ("安装脚本已跳过", "安装包带有安装脚本（通常用于安装后台服务或驱动），MacBox 没有执行它们。功能异常时请改用虚拟 Mac。",
             .installerScriptsSkipped, nil),
            // 认不出的（比如更新的版本加的）照常读取，显示原文
            ("以后才有的问题", "它的说明", nil, nil),
        ]
        let config: [String: Any] = [
            "id": UUID().uuidString, "name": "Old", "bundleIdentifier": "x", "appFolderName": "Old.app", "runtime": "isolated",
            "shareDownloads": true, "showInLaunchpad": true, "resetOnQuit": false, "preferencePrefixes": [String](),
            "isInstaller": false, "createdAt": 0,
            "issues": old.map { ["severity": $0.code?.severity.rawValue ?? "info", "title": $0.title, "detail": $0.detail] },
        ]
        try AppPaths.ensure(paths.url)
        try JSONSerialization.data(withJSONObject: config).write(to: paths.config)

        let issues = try paths.loadConfig().issues
        #expect(issues.map(\.code) == old.map(\.code))
        #expect(issues.map(\.source) == old.map(\.source))
        Localization.$testLanguage.withValue(.chinese) {
            #expect(issues.map(\.localizedTitle) == old.map(\.title))
            // 没通过公证的两条换了说法（spctl 的英文不再原样显示）；自带苹果沙盒的改了说明（本机隔离装不下它，
            // 以前说的“数据存进盒子”不对）。其余照旧
            let shown = old.enumerated().map { index, issue in
                switch index {
                case 2: "有开发者签名，但没有经过公证。打开时 macOS 会询问你是否信任它，请确认来源可靠。"
                case 3: "签名没有通过检查。打开时 macOS 会询问你是否信任它，请确认来源可靠。"
                case 11: "它已经被苹果的沙盒关在自己的容器里，读不到你的文稿和其他 App 的数据。本机隔离装不下它：套上 MacBox 的沙盒后，它一启动就会被系统结束。要完全隔开，请改用虚拟 Mac。"
                default: issue.detail
                }
            }
            #expect(issues.map(\.localizedDetail) == shown)
        }
        Localization.$testLanguage.withValue(.english) {
            #expect(issues[0].localizedTitle == "Passed Apple notarization check")
            #expect(issues[0].localizedDetail == "Developer ID Application: Example Ltd (ABCDE12345)")
            #expect(issues[1].localizedDetail == "Source verified")
            #expect(issues[2].localizedDetail.hasPrefix("Signed by a developer but not notarized. macOS will ask whether you trust it"))
            #expect(issues[3].localizedDetail.hasPrefix("The signature didn’t pass the check. macOS will ask whether you trust it"))
            #expect(issues[5].localizedTitle == "System-wide background service")
            #expect(issues[5].localizedDetail == "Registers a system service that runs at startup.")
            #expect(issues.dropLast().allSatisfy { !$0.localizedTitle.contains(where: \.isHan) && !$0.localizedDetail.contains(where: \.isHan) })
            #expect(issues.last?.localizedTitle == "以后才有的问题" && issues.last?.localizedDetail == "它的说明")
        }

        // 存回去：补上代码，旧版本要读的中文标题、说明原样留着
        var loaded = try paths.loadConfig()
        loaded.name = "Renamed"
        try paths.save(loaded)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.config)) as? [String: Any])
        let savedIssues = try #require(saved["issues"] as? [[String: Any]])
        #expect(savedIssues.map { $0["code"] as? String } == old.map { $0.code?.rawValue })
        #expect(savedIssues.map { $0["title"] as? String } == old.map(\.title))
        #expect(savedIssues.map { $0["detail"] as? String } == old.map(\.detail))
        #expect(try paths.loadConfig().issues == issues)
    }

    @Test("新写入的兼容性问题存代码，不随界面语言变化；标题、说明显示时才按当前语言生成")
    func issueCodes() throws {
        let paths = BoxPaths(url: root.appending(path: "\(UUID().uuidString).box"))
        defer { try? FileManager.default.removeItem(at: root) }
        try AppPaths.ensure(paths.url)
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: "x", appFolderName: "T.app")
        func saved(_ language: AppLanguage) throws -> Data {
            config.issues = Localization.$testLanguage.withValue(language) {
                [CompatibilityIssue(.notNotarized, source: "Unnotarized Developer ID"), CompatibilityIssue(.loginItem),
                 CompatibilityIssue(.notarized)]
            }
            try paths.save(config)
            return try Data(contentsOf: paths.config)
        }
        let data = try saved(.english)
        #expect(data == (try saved(.chinese)))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""code" : "notNotarized""#) && text.contains(#""source" : "Unnotarized Developer ID""#))
        #expect(!text.contains("Failed Apple") && !text.contains("Launch at login"), "存的中文是给旧版本读的，不随界面语言变化")

        let issues = try paths.loadConfig().issues
        #expect(issues.map(\.severity) == [.limited, .limited, .info])
        #expect(issues.map(\.id) == ["notNotarized", "loginItem", "notarized"])
        Localization.$testLanguage.withValue(.english) {
            #expect(issues.map(\.localizedTitle) == ["Failed Apple notarization check", "Launch at login", "Passed Apple notarization check"])
            #expect(issues[2].localizedDetail == "Source verified")
        }
        Localization.$testLanguage.withValue(.chinese) {
            #expect(issues.map(\.localizedTitle) == ["未通过 Apple 公证检查", "开机自启动", "已通过 Apple 公证检查"])
            #expect(issues[0].localizedDetail == "有开发者签名，但没有经过公证。打开时 macOS 会询问你是否信任它，请确认来源可靠。")
        }
    }

    @Test("公证检查：spctl 的英文说法换成当前语言，认不出的不原样显示；通过时的开发者证书名原样显示")
    func notarizationSources() {
        let unsigned = CompatibilityIssue(.notNotarized, source: "no usable signature")
        let unknown = CompatibilityIssue(.notNotarized, source: "some future reason")
        let certificate = CompatibilityIssue(.notarized, source: "Developer ID Application: Example Ltd (ABCDE12345)")
        let notarized = CompatibilityIssue(.notarized, source: "Notarized Developer ID")
        Localization.$testLanguage.withValue(.chinese) {
            #expect(unsigned.localizedDetail == "没有可用的签名。打开时 macOS 会询问你是否信任它，请确认来源可靠。")
            #expect(unknown.localizedDetail.hasPrefix("签名没有通过检查。") && !unknown.localizedDetail.contains("future"))
            #expect(certificate.localizedDetail == "Developer ID Application: Example Ltd (ABCDE12345)")
            #expect(notarized.localizedDetail == "已公证的开发者签名")
        }
        Localization.$testLanguage.withValue(.english) {
            #expect(unsigned.localizedDetail.hasPrefix("No usable signature. macOS will ask"))
            #expect(!unknown.localizedDetail.contains("future"))
            #expect(notarized.localizedDetail == "Notarized developer signature")
        }
        #expect(CompatibilityIssue.Code.spctlSource("Unnotarized Developer ID")?.0 == CompatibilityIssue.Code.spctlSource("unnotarized developer id")?.0)
    }

    @Test("偏好设置前缀：同一应用的两份、前缀包含关系都算重叠；名字相近的不算")
    func preferenceOverlap() {
        #expect(PreferenceLease.overlaps(["com.quark.clouddrive"], ["com.quark.clouddrive"]))
        #expect(PreferenceLease.overlaps(["com.quark.clouddrive"], ["com.quark.clouddrive.helper"]))
        #expect(PreferenceLease.overlaps(["com.quark.clouddrive.helper"], ["com.quark"]))
        #expect(!PreferenceLease.overlaps(["com.quark.clouddrive"], ["com.quark.clouddrive2"]))
        #expect(!PreferenceLease.overlaps(["com.quark.clouddrive"], ["com.netease.youdao"]))
        #expect(PreferenceLease.domain("com.quark.clouddrive.agent", isCoveredBy: ["com.quark.clouddrive"]))
        #expect(!PreferenceLease.domain("com.quark.clouddriveX", isCoveredBy: ["com.quark.clouddrive"]))
    }

    @Test("启动器文件名：斜杠、开头的点、超长名字")
    func launcherFileName() {
        #expect(Launcher.fileName(for: "夸克网盘") == "夸克网盘")
        #expect(Launcher.fileName(for: "A/B") == "A:B")
        #expect(Launcher.fileName(for: ".hidden") == "hidden")
        #expect(Launcher.fileName(for: "...") == "App")
        let long = Launcher.fileName(for: String(repeating: "网", count: 200))
        #expect(long.utf8.count <= 200 && long.allSatisfy { $0 == "网" })
    }

    @Test("拦截记录的进程名：内核截断到 32 字节，截断处可能在汉字中间；短名字不做前缀匹配")
    func loggedProcessName() {
        let long = "MacBoxTest Very Long Executable Name Helper (Renderer)"
        // 实测：内核记成 "MacBoxTest Very Long Executable "（32 字节）
        #expect(ViolationMonitor.loggedName("MacBoxTest Very Long Executable ", matches: long))
        #expect(ViolationMonitor.loggedName("touch", matches: "touch"))
        #expect(!ViolationMonitor.loggedName("mainframe", matches: "main"))
        #expect(!ViolationMonitor.loggedName("MacBoxTest", matches: long), "太短，不是截断出来的")
        let chinese = "夸克网盘助手后台服务进程扩展" // 42 字节
        let cut = String(decoding: Array(chinese.utf8.prefix(32)), as: UTF8.self) // 末尾是半个字
        #expect(cut.hasSuffix("\u{FFFD}"))
        #expect(ViolationMonitor.loggedName(cut, matches: chinese))
    }

    @Test("「添加应用」的文件选择框能选中 .app 包（按扩展名查到的 UTType 不是 App 包）")
    func importPanelAcceptsAppBundles() throws {
        let app = try #require(URL(fileURLWithPath: "/System/Applications/Calculator.app")
            .resourceValues(forKeys: [.contentTypeKey]).contentType)
        #expect(UTType.installers.contains { app.conforms(to: $0) })
        let iso = try #require(UTType(filenameExtension: "iso"))
        #expect(!UTType.installers.contains { iso.conforms(to: $0) }, "取不出 App 的映像不该能选")
    }

    @Test("导入前只看扩展名就能拒绝不支持的东西")
    func supportedTypes() throws {
        for name in ["a.dmg", "A.DMG", "b.app", "c.pkg", "d.mpkg", "e.zip"] {
            try PackageExtractor.checkSupported(URL(fileURLWithPath: "/tmp/\(name)"))
        }
        for name in ["a.iso", "folder", "b.txt"] {
            #expect(throws: MacBoxError.self) { try PackageExtractor.checkSupported(URL(fileURLWithPath: "/tmp/\(name)")) }
        }
    }
}

private extension Character {
    var isHan: Bool { unicodeScalars.first?.properties.isIdeographic == true }
}
