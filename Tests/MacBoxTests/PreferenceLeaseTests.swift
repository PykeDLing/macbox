import Foundation
import Testing
@testable import MacBox

/// 偏好设置借出/收回。系统偏好设置目录换成临时目录，不碰真实的 ~/Library/Preferences；
/// “App 在运行中修改设置”用另一个进程（defaults）模拟，和真实情况一样经由 cfprefsd
@Suite("偏好设置借出与收回", .serialized)
struct PreferenceLeaseTests {
    let root: URL
    let box: BoxPaths
    let system: URL
    let domain = "dev.macboxtest.app"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")
        box = BoxPaths(url: root.appending(path: "T.box"))
        system = root.appending(path: "SystemPreferences")
        try AppPaths.ensure(box.prefs)
        try AppPaths.ensure(system)
    }

    func lease() -> PreferenceLease {
        var lease = PreferenceLease(box: box, prefixes: [domain])
        lease.systemPrefs = system
        return lease
    }

    /// 以另一个进程写入系统里的设置（相当于本机 App 或盒子里的 App）
    func systemWrite(_ name: String, _ key: String, _ value: String) async throws {
        try await Shell.run("/usr/bin/defaults", ["write", system.appending(path: name).path, key, "-string", value])
    }

    func systemRead(_ name: String) async -> [String: String] {
        let path = system.appending(path: name).path
        let ref = path as CFString
        CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let keys = CFPreferencesCopyKeyList(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else { return [:] }
        return CFPreferencesCopyMultiple(keys as CFArray, ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: String] ?? [:]
    }

    func boxContent(_ name: String) -> [String: String]? {
        NSDictionary(contentsOf: box.prefs.appending(path: "\(name).plist")) as? [String: String]
    }

    func saveBox(_ name: String, _ content: [String: String]) throws {
        try PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0)
            .write(to: box.prefs.appending(path: "\(name).plist"))
    }

    /// 盒子外、不属于这个 App 的东西（另一个 App 的设置、任意 .plist）
    var victims: URL { root.appending(path: "victim") }
    let foreign = "dev.macboxtest.other"

    func cleanUp() async {
        var paths = [domain, "\(domain).helper", "\(domain).native-only", "\(domain).linked", foreign]
            .map { system.appending(path: $0).path }
        paths += ["dev.macboxtest.victim-budget", "dev.macboxtest.victim-overwrite"].map { victims.appending(path: $0).path }
        for path in paths {
            _ = try? await Shell.run("/usr/bin/defaults", ["delete", path])
        }
        // cfprefsd 会把清空的域写回一个空 plist：连同目录一起删掉
        _ = chmod(box.prefs.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func writeJournal(_ json: String) throws {
        try json.write(to: box.leaseJournal, atomically: true, encoding: .utf8)
    }

    func saveNativeBackup(_ name: String, _ content: [String: String]) throws {
        try AppPaths.ensure(box.nativePrefsBackup)
        try PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0)
            .write(to: box.nativePrefsBackup.appending(path: "\(name).plist"))
    }

    @Test("借出时整体替换，不与本机设置合并；收回后本机设置原样恢复")
    func replaceNotMerge() async throws {
        try await systemWrite(domain, "token", "native-secret")
        try await systemWrite(domain, "who", "native")
        try saveBox(domain, ["who": "box"])

        try await lease().checkIn()
        #expect(await systemRead(domain) == ["who": "box"], "本机的 token 不应被盒子里的 App 看到")

        try await systemWrite(domain, "added", "by-box-app")
        try await lease().checkOut()

        #expect(await systemRead(domain) == ["token": "native-secret", "who": "native"], "盒子写入的键不应留在本机")
        #expect(boxContent(domain) == ["who": "box", "added": "by-box-app"])
        await cleanUp()
    }

    @Test("运行中新建的域收进盒子并从系统删除；本机独有的域借出期间被清空、之后恢复")
    func domainsAppearAndDisappear() async throws {
        try await systemWrite("\(domain).native-only", "k", "v")
        try await lease().checkIn()
        #expect(await systemRead("\(domain).native-only").isEmpty)

        try await systemWrite("\(domain).helper", "h", "1")
        try await lease().checkOut()

        #expect(boxContent("\(domain).helper") == ["h": "1"])
        #expect(await systemRead("\(domain).helper").isEmpty)
        // cfprefsd 稍后会刷新缓存：空域的文件不能再冒出来
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: system.appending(path: "\(domain).helper.plist").path))
        #expect(await systemRead("\(domain).native-only") == ["k": "v"])
        #expect(boxContent("\(domain).native-only") == nil)
        await cleanUp()
    }

    @Test("MacBox 在借出期间崩溃：下次启动按日志收回并恢复")
    func crashRecovery() async throws {
        try await systemWrite(domain, "who", "native")
        try saveBox(domain, ["who": "box"])
        try await lease().checkIn()
        try await systemWrite(domain, "who", "box-changed")
        // 进程“崩溃”：不调用 checkOut。重启后用新的实例恢复
        let restarted = lease()
        #expect(restarted.isOutstanding)
        try await restarted.checkOut()
        #expect(!restarted.isOutstanding)
        #expect(await systemRead(domain) == ["who": "native"])
        #expect(boxContent(domain) == ["who": "box-changed"])
        // 重复收回不会再改动任何东西
        try await restarted.checkOut()
        #expect(boxContent(domain) == ["who": "box-changed"])
        await cleanUp()
    }

    @Test("收回进行到一半崩溃：重做时不会把本机设置当成盒子的收进去")
    func crashDuringReturn() async throws {
        try await systemWrite(domain, "who", "native")
        try saveBox(domain, ["who": "box"])
        try await lease().checkIn()
        try await lease().checkOut()
        // 模拟：收回阶段写完日志、恢复了本机设置后崩溃
        let journal = box.prefs.appending(path: ".lease.json")
        try #"{"phase":"returning","nativeDomains":["dev.macboxtest.app"],"lentDomains":[]}"#
            .write(to: journal, atomically: true, encoding: .utf8)
        try AppPaths.ensure(box.nativePrefsBackup)
        try PropertyListSerialization.data(fromPropertyList: ["who": "native"], format: .binary, options: 0)
            .write(to: box.nativePrefsBackup.appending(path: "\(domain).plist"))
        try await lease().checkOut()
        #expect(boxContent(domain) == ["who": "box"], "盒子里的设置不应被本机设置覆盖")
        #expect(await systemRead(domain) == ["who": "native"])
        await cleanUp()
    }

    @Test("兼容旧版：只留下 .native 备份目录时也能恢复")
    func legacyRecovery() async throws {
        try await systemWrite(domain, "who", "box-running")
        try AppPaths.ensure(box.nativePrefsBackup)
        try PropertyListSerialization.data(fromPropertyList: ["who": "native"], format: .binary, options: 0)
            .write(to: box.nativePrefsBackup.appending(path: "\(domain).plist"))
        #expect(lease().isOutstanding)
        try await lease().checkOut()
        #expect(await systemRead(domain) == ["who": "native"])
        #expect(boxContent(domain) == ["who": "box-running"])
        await cleanUp()
    }

    // MARK: - 盒子里的 App 改过日志和 Prefs

    /// 日志、Prefs 都在盒子目录里，沙盒里的 App 改得到；收回时不在沙盒里的 MacBox 不能照着它们去动盒子外的东西
    @Test("日志和 Prefs 被盒子里的 App 改过：带 .. 的域、绝对路径、别的 App 的域、指向盒子外的链接一律不碰")
    func tamperedJournalAndPrefs() async throws {
        func victimWrite(_ name: String, _ key: String, _ value: String) async throws {
            try await Shell.run("/usr/bin/defaults", ["write", victims.appending(path: name).path, key, "-string", value])
        }
        func victimRead(_ name: String) -> [String: String]? {
            NSDictionary(contentsOf: victims.appending(path: "\(name).plist")) as? [String: String]
        }
        try AppPaths.ensure(victims)
        try await victimWrite("dev.macboxtest.victim-budget", "secret", "keep-me")
        try await victimWrite("dev.macboxtest.victim-overwrite", "who", "victim")
        try await systemWrite(foreign, "who", "other-app")
        try await systemWrite(domain, "who", "native")
        try saveBox(domain, ["who": "box"])
        // App 往 Prefs 里放：别的 App 的域、指向盒子外 .plist 的链接（名字在前缀之内）
        try saveBox(foreign, ["who": "planted-by-box"])
        try FileManager.default.createSymbolicLink(at: box.prefs.appending(path: "\(domain).linked.plist"),
                                                   withDestinationURL: victims.appending(path: "dev.macboxtest.victim-budget.plist"))

        try await lease().checkIn()
        #expect(await systemRead(foreign) == ["who": "other-app"], "不属于这个盒子的域不借出")
        #expect(await systemRead("\(domain).linked").isEmpty, "不能顺着链接把盒子外的 plist 借给 App")
        #expect(await systemRead(domain) == ["who": "box"])

        // 借出期间 App 改写日志。域名以前缀开头，经过一个名字也在前缀之内的目录用 .. 跳出去——只查前缀拦不住
        let escape = "\(domain).x/../../victim"
        for directory in [system, box.prefs, box.nativePrefsBackup] {
            try AppPaths.ensure(directory.appending(path: "\(domain).x"))
        }
        try AppPaths.ensure(box.url.appending(path: "victim")) // Prefs/<domain>.x/../../victim
        // 假的“本机备份”：.native/<domain>.x/../../victim 就是 Prefs/victim
        try AppPaths.ensure(box.prefs.appending(path: "victim"))
        try PropertyListSerialization.data(fromPropertyList: ["who": "injected"], format: .binary, options: 0)
            .write(to: box.prefs.appending(path: "victim/dev.macboxtest.victim-overwrite.plist"))
        try saveNativeBackup(foreign, ["who": "injected"])
        try writeJournal("""
            {"phase":"lent",
             "nativeDomains":["\(escape)/dev.macboxtest.victim-overwrite","\(foreign)"],
             "lentDomains":["\(escape)/dev.macboxtest.victim-budget","\(escape)/dev.macboxtest.victim-overwrite",
                            "\(foreign)","\(victims.path)/dev.macboxtest.victim-budget","../\(domain)"]}
            """)
        try await systemWrite(domain, "who", "box-changed")

        try await lease().checkOut()

        #expect(victimRead("dev.macboxtest.victim-budget") == ["secret": "keep-me"], "盒子外的 .plist 不能被删除")
        #expect(victimRead("dev.macboxtest.victim-overwrite") == ["who": "victim"], "盒子外的 .plist 不能被改写")
        #expect(await systemRead(foreign) == ["who": "other-app"], "别的 App 的设置不能被改写")
        #expect(boxContent(foreign) == ["who": "planted-by-box"], "别的 App 的设置不能被收进盒子")
        #expect(FileOps.contents(of: box.url.appending(path: "victim")).isEmpty, "盒子外的设置不能被收进盒子")
        #expect(await systemRead(domain) == ["who": "native"])
        #expect(boxContent(domain) == ["who": "box-changed"])
        #expect(!lease().isOutstanding)
        await cleanUp()
    }

    @Test("借出在备份、替换阶段崩溃：已备份的域按备份恢复，没备份的本机域保持原样，系统里的内容不收进盒子")
    func crashWhileLending() async throws {
        let notBackedUp = "\(domain).native-only", boxOnly = "\(domain).helper"
        try await systemWrite(notBackedUp, "k", "native")
        try saveBox(domain, ["who": "box"])
        try saveBox(boxOnly, ["h": "box"])
        // 本机的 domain 已备份并换成了盒子的内容，盒子独有的 helper 也已放进系统；native-only 还没备份、没动过
        try saveNativeBackup(domain, ["who": "native"])
        try await systemWrite(domain, "who", "box")
        try await systemWrite(boxOnly, "h", "box")
        try writeJournal("""
            {"phase":"lending","nativeDomains":["\(domain)","\(notBackedUp)"],"lentDomains":["\(domain)","\(boxOnly)"]}
            """)
        #expect(lease().isOutstanding)

        try await lease().checkOut()

        #expect(await systemRead(domain) == ["who": "native"])
        #expect(await systemRead(notBackedUp) == ["k": "native"], "没备份的本机域从未被改动，不能被清空")
        #expect(await systemRead(boxOnly).isEmpty)
        #expect(boxContent(domain) == ["who": "box"], "借出没完成，系统里的不是 App 运行后的内容，不能收进盒子")
        #expect(boxContent(boxOnly) == ["h": "box"])
        #expect(boxContent(notBackedUp) == nil)
        #expect(!lease().isOutstanding)
        await cleanUp()
    }

    @Test("收回失败时报出是哪一步、哪个域；日志和备份留着，之后可以接着收回")
    func checkOutFailureIsDescriptive() async throws {
        try await systemWrite(domain, "who", "native")
        try saveBox(domain, ["who": "box"])
        try await lease().checkIn()
        try await systemWrite(domain, "who", "box-changed")

        // 存回盒子时失败（磁盘满、权限不对）
        #expect(chmod(box.prefs.path, 0o555) == 0)
        let error = await #expect(throws: (any Error).self) { try await lease().checkOut() }
        let message = error?.localizedDescription ?? ""
        #expect(message.contains(domain))
        #expect(message.contains(L("存回盒子", "back to the box")), "要说明卡在哪一步：\(message)")
        #expect(lease().isOutstanding, "失败时不能丢掉日志和本机设置的备份")
        #expect(await systemRead(domain) == ["who": "box-changed"])

        #expect(chmod(box.prefs.path, 0o755) == 0)
        try await lease().checkOut()
        #expect(!lease().isOutstanding)
        #expect(await systemRead(domain) == ["who": "native"])
        #expect(boxContent(domain) == ["who": "box-changed"])
        await cleanUp()
    }
}
