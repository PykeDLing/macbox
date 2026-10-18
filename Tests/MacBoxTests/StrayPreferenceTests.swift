import Foundation
import Testing
@testable import MacBox

/// 写在盒子外的偏好设置：认出运行期间新写下、可能属于这个应用的域，收进盒子之后照常借出、收回。
/// 系统偏好设置目录换成临时目录，不碰真实的 ~/Library/Preferences；写进去的域一律以 dev.macboxtest. 开头
@Suite("写在盒子外的设置", .serialized)
struct StrayPreferenceTests {
    let root: URL
    let box: BoxPaths
    let system: URL
    let app = "dev.macboxtest.stray.app"
    let sdk = "dev.macboxtest.stray.sdk"
    let uuid = "383474A0-9345-5BC0-8419-E5DB4A074DC4"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-\(UUID().uuidString)")
        box = BoxPaths(url: root.appending(path: "T.box"))
        system = root.appending(path: "SystemPreferences")
        try AppPaths.ensure(box.prefs)
        try AppPaths.ensure(system.appending(path: "ByHost"))
    }

    func lease(_ prefixes: [String]) -> PreferenceLease {
        var lease = PreferenceLease(box: box, prefixes: prefixes)
        lease.systemPrefs = system
        return lease
    }

    /// 直接放一个 .plist 文件，不经过 cfprefsd（只用来认候选，不当作设置读写）
    func plant(_ relative: String, _ content: [String: Any] = ["k": 1], modified: Date? = nil) throws {
        let url = system.appending(path: relative)
        try PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    /// 以另一个进程经由 cfprefsd 写入系统里的设置（相当于盒子里的 App）
    func systemWrite(_ name: String, _ key: String, _ value: String) async throws {
        try await Shell.run("/usr/bin/defaults", ["write", system.appending(path: name).path, key, "-string", value])
    }

    func systemRead(_ name: String) -> [String: String] {
        let ref = system.appending(path: name).path as CFString
        CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let keys = CFPreferencesCopyKeyList(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else { return [:] }
        return CFPreferencesCopyMultiple(keys as CFArray, ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: String] ?? [:]
    }

    func systemFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: system.appending(path: "\(name).plist").path)
    }

    func boxContent(_ name: String) -> [String: String]? {
        NSDictionary(contentsOf: box.prefs.appending(path: "\(name).plist")) as? [String: String]
    }

    func saveBox(_ name: String, _ content: [String: String]) throws {
        try PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0)
            .write(to: box.prefs.appending(path: "\(name).plist"))
    }

    func cleanUp() async {
        for name in [app, sdk, "\(sdk).cache", "\(sdk).native"] {
            _ = try? await Shell.run("/usr/bin/defaults", ["delete", system.appending(path: name).path])
        }
        // cfprefsd 会把清空的域写回一个空 plist：连同目录一起删掉
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 认候选

    @Test("候选：运行期间新出现、不在借出范围里、认不出是别人的；原有被改写的、挪进来的旧文件、借出范围里的不算。ByHost 的借出范围里的也算")
    func candidates() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try plant("dev.macboxtest.stray.native.plist")
        try plant("dev.macboxtest.stray.rewritten.plist")
        try plant("ByHost/dev.macboxtest.stray.old.\(uuid).plist")
        let before = SystemPreferenceFiles.list(system)
        try await Task.sleep(for: .milliseconds(20))

        try plant("\(sdk).plist", ["deviceId": "x", "SUEnableAutomaticChecks": true])
        try plant("\(app).helper.plist") // 借出范围里的：已经收进盒子了
        try plant("dev.macboxtest.stray.rewritten.plist", ["k": 2]) // 运行前就有：本机的内容
        try plant("dev.macboxtest.stray.moved.plist", modified: Date(timeIntervalSinceNow: -3600)) // 挪进来的旧文件
        try plant("dev.macboxtest.stray.installed.helper.plist") // 本机装着的另一个 App 的
        try plant(".dev.macboxtest.stray.hidden.plist")
        try plant("dev.macboxtest.stray.notes.txt")
        try plant("ByHost/\(app).\(uuid).plist") // 应用自己的 ByHost：借出不管，写在盒子外
        try plant("ByHost/\(sdk).0A1B2C3D4E5F.plist", ["h": 1]) // 更早的系统用网卡地址
        try plant("ByHost/\(sdk).\(uuid).plist") // 同一个域另一种写法：列一次
        try plant("ByHost/dev.macboxtest.stray.nohost.plist") // 认不出是哪台 Mac 的
        try FileManager.default.createSymbolicLink(at: system.appending(path: "dev.macboxtest.stray.link.plist"),
                                                   withDestinationURL: system.appending(path: "\(sdk).plist"))

        var asked = 0
        let strays = SystemPreferenceFiles.list(system).strays(since: before, prefixes: [app], identifier: app) {
            asked += 1
            return [app, "dev.macboxtest.stray.installed"] // 本机也装着同一个 App：不算其他 App
        }
        #expect(strays.map(\.id) == [sdk, "ByHost/\(app)", "ByHost/\(sdk)"])
        #expect(strays.first?.keys == ["SUEnableAutomaticChecks", "deviceId"], "只记键名")
        #expect(strays.last?.keys == ["h"])
        #expect(asked == 1)

        let again = SystemPreferenceFiles.list(system)
        #expect(again.strays(since: again, prefixes: [app], identifier: app) { asked += 1; return [] }.isEmpty)
        #expect(asked == 1, "没有新文件时不去读本机装了哪些 App")
    }

    @Test("认得出不属于这个应用的：苹果的、不是单个文件名的、和本机装着的其他 App 重叠的；整个厂商的名字收不进盒子；ByHost 文件名里的域")
    func rules() {
        let own = "dev.macboxtest.rules.app"
        let installed: Set<String> = [own, "com.tencent.qq"]
        func foreign(_ domain: String) -> Bool { StrayPreference.isForeign(domain, identifier: own, installed: installed) }
        for domain in ["com.apple.finder", "com.apple", "COM.Apple.Safari", ".GlobalPreferences", "a/b", "dev.macboxtest..x", ""] {
            #expect(foreign(domain), "\(domain)")
        }
        #expect(foreign("com.tencent.qq") && foreign("com.tencent.qq.helper") && foreign("com.tencent") && foreign("COM.TENCENT.QQ"))
        #expect(!foreign("com.tencent.bugly"))
        #expect(!foreign("dev.macboxtest.rules"), "本机装着的同一个 App 不算其他 App")
        #expect(!foreign("ZoomChat") && !foreign("21920772483"), "不带点的域也可能是它的")

        for domain in ["com.tencent", "jp.co.canon", "com.cn.foo", "cn.com.foo"] { #expect(StrayPreference.isVendorWide(domain), "\(domain)") }
        for domain in ["com.tencent.bugly", "jp.co.canon.ij", "foo", "dev.macboxtest.rules.sdk"] { #expect(!StrayPreference.isVendorWide(domain), "\(domain)") }

        #expect(SystemPreferenceFiles.byHostDomain("com.foo.bar.\(uuid)") == "com.foo.bar")
        #expect(SystemPreferenceFiles.byHostDomain("com.foo.0a1b2c3d4e5f") == "com.foo")
        #expect(SystemPreferenceFiles.byHostDomain("com.foo.bar") == nil)
        #expect(SystemPreferenceFiles.byHostDomain(uuid) == nil)
        #expect(SystemPreferenceFiles.byHostDomain(".\(uuid)") == nil)
    }

    // MARK: - 报告

    @Test("运行前后对比时一起比出来；新报告存取往返，旧报告没有这一栏照常读取；导出的文字和概要里有这一栏")
    func report() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: app, appFolderName: "T.app")
        config.preferencePrefixes = [app]
        config.shareDownloads = false
        try AppPaths.ensure(box.home)
        try AppPaths.ensure(box.appDirectory)
        let before = await RunSnapshot.take(box, config: config, systemPrefs: system)
        try await Task.sleep(for: .milliseconds(20))
        try plant("\(sdk).plist", ["deviceId": "x"])
        let changes = await before.changes(box, config: config, preferencesReturned: false, installed: { [] })
        #expect(changes.strayPreferences == [StrayPreference(domain: sdk, byHost: false, keys: ["deviceId"])],
                "设置没能收回时也照样比：借出的域都在借出范围里，不会算进来")

        var report = RunReport(config: config)
        report.endedAt = report.startedAt.addingTimeInterval(60)
        report.strayPreferences = changes.strayPreferences + [StrayPreference(domain: app, byHost: true, keys: [])]
        try await RunReport.save(report, in: box)
        // 0.4.0 写下的报告：没有 strayPreferences
        let old = """
        {"id":"\(UUID().uuidString)","appName":"Old","bundleIdentifier":"x","startedAt":0,"endedAt":30,"networkBlocked":false,
         "sharesDownloads":true,"files":[],"fileTotals":{"created":0,"modified":0,"deleted":0,"bytes":0},"preferences":[],
         "servers":[],"programs":[],"blocks":[]}
        """
        try old.write(to: box.reports.appending(path: "0000000000-old.json"), atomically: true, encoding: .utf8)
        let loaded = await RunReport.load(from: box)
        #expect(loaded.count == 2)
        #expect(loaded.first { $0.id == report.id }?.strayPreferences == report.strayPreferences)
        let legacy = try #require(loaded.first { $0.appName == "Old" })
        #expect(legacy.strayPreferences == nil && legacy.files == [])

        Localization.$testLanguage.withValue(.chinese) {
            let text = report.markdown()
            for expected in ["## 可能属于这个应用、但写在了盒子外的设置", "- `\(sdk)`", "`deviceId`", "- `\(app)`（仅限本机）"] {
                #expect(text.contains(expected), "\(expected)")
            }
            #expect(report.summaryLine.contains("2 个设置文件写在盒子外"))
            #expect(legacy.markdown().contains("旧版 MacBox 的报告没有这一项。"))
            #expect(!legacy.summaryLine.contains("盒子外"))
        }
        Localization.$testLanguage.withValue(.english) {
            #expect(report.markdown().contains("- `\(app)` (this Mac only)"))
            #expect(report.summaryLine.contains("2 preference files outside the box"))
        }
    }

    @Test("报告页每一项的状态：仅限本机的、整个厂商的名字只列出；在借出范围里的是已收进盒子")
    @MainActor
    func status() {
        defer { try? FileManager.default.removeItem(at: root) }
        var config = BoxConfig(id: UUID(), name: "T", bundleIdentifier: app, appFolderName: "T.app")
        config.preferencePrefixes = [app, sdk]
        let model = Box(paths: box, config: config)
        func status(_ domain: String, byHost: Bool = false) -> Box.StrayStatus {
            model.status(of: StrayPreference(domain: domain, byHost: byHost, keys: []))
        }
        #expect(status(sdk) == .adopted && status("\(sdk).cache") == .adopted)
        #expect(status("dev.macboxtest.stray.other") == .adoptable)
        #expect(status(app, byHost: true) != .adopted && status(app, byHost: true) != .adoptable, "借出不管 ByHost")
        #expect(status("dev.macboxtest") != .adoptable, "整个厂商的名字")
    }

    // MARK: - 收进盒子

    @Test("收进盒子：内容存进盒子、从系统删除、前缀加上，<域>.* 里这次新写的一起；之后借出时放回系统，收回时存回盒子并从系统删除")
    func adoptThenLend() async throws {
        try await systemWrite(sdk, "deviceId", "from-run")
        try await systemWrite("\(sdk).cache", "c", "1")
        try saveBox(app, ["who": "box"])

        let prefixes = try await lease([app]).adopt(sdk, strays: [sdk, "\(sdk).cache"], installed: [app], ownIdentifier: app,
                                                   otherBoxes: [["dev.macboxtest.another"]])
        #expect(prefixes == [app, sdk])
        #expect(boxContent(sdk) == ["deviceId": "from-run"])
        #expect(boxContent("\(sdk).cache") == ["c": "1"])
        #expect(systemRead(sdk).isEmpty && systemRead("\(sdk).cache").isEmpty)
        // cfprefsd 稍后会刷新缓存：空域的文件不能再冒出来
        try await Task.sleep(for: .seconds(3))
        #expect(!systemFileExists(sdk) && !systemFileExists("\(sdk).cache"))
        // 已经在借出范围里了：再收一次什么也不做
        #expect(try await lease(prefixes).adopt(sdk, strays: [], installed: [], ownIdentifier: app, otherBoxes: []) == prefixes)

        // 下次运行：盒子有、本机没有的域，借出时放进系统，收回时存回盒子再从系统删除
        let next = lease(prefixes)
        try await next.checkIn()
        #expect(systemRead(sdk) == ["deviceId": "from-run"])
        #expect(systemRead(app) == ["who": "box"])
        try await systemWrite(sdk, "added", "next-run")
        try await next.checkOut()
        #expect(!next.isOutstanding)
        #expect(boxContent(sdk) == ["deviceId": "from-run", "added": "next-run"])
        #expect(systemRead(sdk).isEmpty && systemRead("\(sdk).cache").isEmpty, "收进盒子的设置不能再留在系统里")
        #expect(systemRead(app).isEmpty)
        await cleanUp()
    }

    @Test("收不进盒子的几种：不在报告的候选里、运行前就有的子域、整个厂商的名字、和本机装着的 App 或别的盒子重叠、借出没收回——什么都不动")
    func refusals() async throws {
        try await systemWrite(sdk, "deviceId", "from-run")
        try await systemWrite("\(sdk).native", "k", "native")
        func refusal(_ domain: String? = nil, strays: Set<String>? = nil, installed: Set<String> = [],
                     otherBoxes: [[String]] = []) async -> String {
            let domain = domain ?? sdk
            let error = await #expect(throws: (any Error).self, "\(domain)") {
                try await lease([app]).adopt(domain, strays: strays ?? [domain], installed: installed, ownIdentifier: app,
                                             otherBoxes: otherBoxes)
            }
            return error?.localizedDescription ?? ""
        }
        #expect(await refusal(strays: []).contains(sdk))
        #expect(await refusal().contains("\(sdk).native"), "运行前就有的子域是本机的设置，不能收进盒子")
        #expect(await refusal("dev.macboxtest").contains(L("厂商", "vendor")))
        #expect(await refusal(strays: [sdk, "\(sdk).native"], installed: ["\(sdk).helper"]).contains("\(sdk).helper"))
        #expect(await refusal(strays: [sdk, "\(sdk).native"], otherBoxes: [["\(sdk).native"]]).contains(L("另一个盒子", "another box")))
        // 借出没收回
        try saveBox(app, ["who": "box"])
        try await lease([app]).checkIn()
        #expect(await refusal(strays: [sdk, "\(sdk).native"]).contains(L("没收回", "returned")))
        try await lease([app]).checkOut()

        #expect(systemRead(sdk) == ["deviceId": "from-run"])
        #expect(systemRead("\(sdk).native") == ["k": "native"])
        #expect(boxContent(sdk) == nil && boxContent("\(sdk).native") == nil)
        await cleanUp()
    }

    @Test("收到一半崩溃：已经从系统删掉、前缀还没加时，再收一次补上前缀，盒子里的内容不丢；还没删掉时，再收一次按系统里现在的内容收")
    func adoptAfterCrash() async throws {
        // 存进盒子、从系统删掉之后崩溃
        try saveBox(sdk, ["deviceId": "saved"])
        var prefixes = try await lease([app]).adopt(sdk, strays: [sdk], installed: [], ownIdentifier: app, otherBoxes: [])
        #expect(prefixes == [app, sdk])
        #expect(boxContent(sdk) == ["deviceId": "saved"])

        // 存进盒子之后、从系统删掉之前崩溃：系统里的是更新的
        try saveBox("\(sdk).cache", ["c": "old"])
        try await systemWrite("\(sdk).cache", "c", "new")
        prefixes = try await lease([app]).adopt("\(sdk).cache", strays: ["\(sdk).cache"], installed: [], ownIdentifier: app,
                                                otherBoxes: [])
        #expect(prefixes == [app, "\(sdk).cache"])
        #expect(boxContent("\(sdk).cache") == ["c": "new"])
        #expect(systemRead("\(sdk).cache").isEmpty)

        let next = lease([app, sdk])
        try await next.checkIn()
        #expect(systemRead(sdk) == ["deviceId": "saved"])
        try await next.checkOut()
        #expect(systemRead(sdk).isEmpty)
        await cleanUp()
    }
}
