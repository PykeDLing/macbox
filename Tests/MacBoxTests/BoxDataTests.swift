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
        #expect(read(file) == nil && read(paths.keychainPassword) == nil)

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
