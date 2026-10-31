import Foundation
import Testing
@testable import MacBox

/// 界面文字（String Catalog）：每句都有英文、占位符对得上，单复数、列表、存给旧版本的中文。
/// 只读 Resources 里的文件和编译到临时目录的译文，不碰任何真实数据
@Suite("String Catalog")
struct LocalizationTests {
    typealias Entry = [String: Any]

    static func catalog(_ name: String) throws -> [String: Entry] {
        let data = try Data(contentsOf: English.repo.appending(path: "Resources/\(name).xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "zh-Hans")
        return try #require(json["strings"] as? [String: Entry])
    }

    /// 一句里的占位符（不含 %%），去掉位置编号：“%2$lld” → “%lld”
    static func specifiers(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDuUixXoOfFeEgGcCsSpaA]|%%/)
            .map { String($0.output) }
            .filter { $0 != "%%" }
            .map { $0.replacing(/\d+\$/, with: "") }
    }

    /// 英文的几种说法：没有按数量变化时只有一种
    static func englishForms(_ entry: Entry) -> [String: String]? {
        guard let en = (entry["localizations"] as? Entry)?["en"] as? Entry else { return nil }
        func value(_ unit: Any?) -> String? {
            guard let unit = (unit as? Entry)?["stringUnit"] as? Entry, unit["state"] as? String == "translated" else { return nil }
            return unit["value"] as? String
        }
        if let plural = (en["variations"] as? Entry)?["plural"] as? Entry {
            var forms: [String: String] = [:]
            for (category, unit) in plural { forms[category] = value(unit) }
            return forms
        }
        return value(en).map { ["": $0] }
    }

    @Test("每句都有英文译文，占位符和原文对得上；没有不再用的旧条目")
    func catalogComplete() throws {
        for (key, entry) in try Self.catalog("Localizable") {
            #expect(entry["extractionState"] as? String != "stale", "代码里已经不用了，请从 Localizable.xcstrings 删掉：\(key)")
            if entry["shouldTranslate"] as? Bool == false { continue }
            // 显式的键（report.stat.servers 这种）原文在 defaultValue 里，sync 记成简体中文的那一项
            let source = ((entry["localizations"] as? Entry)?["zh-Hans"] as? Entry)
                .flatMap { ($0["stringUnit"] as? Entry)?["value"] as? String } ?? key
            guard let forms = Self.englishForms(entry), !forms.isEmpty else {
                Issue.record("没有英文译文（在 Xcode 里打开 Resources/Localizable.xcstrings 补上）：\(key)")
                continue
            }
            let expected = Self.specifiers(source).sorted()
            for (category, value) in forms {
                let found = Self.specifiers(value).sorted()
                if category == "one" {
                    // 单数的说法可以不写出数字（“an app opened from Spotlight”），其余占位符要在
                    #expect(Set(found).isSubset(of: Set(expected)) && found.count >= expected.count - 1, "\(key) → \(value)")
                } else {
                    #expect(found == expected, "占位符和原文不一致：\(key) → \(value)")
                }
                #expect(!value.isEmpty, "\(key)")
                // 和源代码里的英文一样用弯撇号（见 InterfaceTextTests）
                #expect(!value.contains(/[A-Za-z]'[A-Za-z]/), "直撇号要换成 ’：\(value)")
            }
            if forms[""] == nil { #expect(forms["one"] != nil && forms["other"] != nil, "按数量变化要有 one 和 other：\(key)") }
        }
    }

    @Test("Info.plist：开发语言是英文（中英文都不在偏好语言里时显示英文），声明了两种语言；文稿类型名称有英文")
    func infoPlist() throws {
        let data = try Data(contentsOf: English.repo.appending(path: "Resources/Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(info["CFBundleLocalizations"] as? [String] == ["zh-Hans", "en"])
        let strings = try Self.catalog("InfoPlist")
        let types = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).compactMap { $0["CFBundleTypeName"] as? String }
        #expect(!types.isEmpty)
        for name in types { #expect(strings[name].flatMap(Self.englishForms)?[""] != nil, "\(name)") }
    }

    @Test("偏好语言里中英文都没有时显示英文；简体中文查不到时用中文原文，不退回英文（靠 zh-Hans.lproj 里的空表）")
    func fallbackLanguage() async throws {
        // 照 App 的配置跑一个小程序：编进 App 的 Info.plist（开发语言英文），旁边放编译出的 en.lproj 和 zh-Hans.lproj。
        // 按某种语言直接取（localizedString(…localizations:)）不会退回开发语言，测不出来，只能真的跑一次
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try AppPaths.ensure(folder)
        for lproj in ["en.lproj", "zh-Hans.lproj"] {
            try FileManager.default.copyItem(at: English.compiled.appending(path: lproj), to: folder.appending(path: lproj))
        }
        let source = folder.appending(path: "probe.swift")
        try #"""
        import Foundation
        print(String(localized: "添加应用"), String(localized: "写入 \(2) 个文件"), separator: "|")
        """#.write(to: source, atomically: true, encoding: .utf8)
        let probe = folder.appending(path: "probe")
        try await Shell.run("/usr/bin/xcrun", ["swiftc", "-o", probe.path, source.path,
                                               "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                               "-Xlinker", English.repo.appending(path: "Resources/Info.plist").path])
        func shown(_ languages: String) async throws -> String {
            try await Shell.run(probe.path, ["-AppleLanguages", "(\(languages))"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let chinese = "添加应用|写入 2 个文件", english = "Add App|2 files written"
        #expect(try await shown("zh-Hans") == chinese)
        #expect(try await shown("fr, zh-Hans") == chinese)
        #expect(try await shown("en") == english)
        #expect(try await shown("ja") == english)
        #expect(try await shown("ko, fr") == english)
        // 没有空表时，简体中文会退回去查英文：这就是 build.sh 要放空表的原因
        for table in try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "zh-Hans.lproj").path) {
            try FileManager.default.removeItem(at: folder.appending(path: "zh-Hans.lproj/\(table)"))
        }
        #expect(try await shown("zh-Hans") != chinese)
    }

    @Test("按数量变化：一个和几个说法不同")
    func plurals() {
        #expect(English.text("写入 \(1) 个文件") == "1 file written")
        #expect(English.text("写入 \(2) 个文件") == "2 files written")
        #expect(English.text("拦下 \(1) 次") == "1 attempt blocked")
        #expect(English.text("\(1) 个从聚焦打开的应用") == "an app opened from Spotlight")
        #expect(English.text("\(3) 个从聚焦打开的应用") == "3 apps opened from Spotlight")
        let list = "“Alpha.app”"
        #expect(English.text("「传出」里有 \(1) 项无法加上隔离标记：\(list)。打开之前请确认它们可信。")
            == "An item in “传出” (Outgoing) couldn’t be quarantined: “Alpha.app”. Make sure you trust it before opening it.")
        #expect(English.text("「传出」里有 \(4) 项无法加上隔离标记：\(list)。打开之前请确认它们可信。").hasPrefix("4 items in “传出”"))
        // 参数换了顺序的
        #expect(English.text("其中有\("「文稿」")里的文件夹：「\("Quark")」第一次写入时，macOS 可能会问是否允许它访问\("")。这是在问盒子里的这个应用，允许后它才能写入。macOS 会记住这个选择，删除应用后也还在，可以在「系统设置 › 隐私与安全性 › 文件与文件夹」里撤销。")
            .hasPrefix("Some of these folders are in places macOS protects (「文稿」). The first time “Quark” writes there"))
    }

    @Test("名字列表：按界面语言加引号、连起来；界面语言代码也在 catalog 里")
    func lists() {
        // 测试里没有译文，界面语言是简体中文
        #expect(quotedList(["夸克"]) == "「夸克」")
        #expect(quotedList(["甲", "乙", "丙"]) == "「甲」、「乙」和「丙」")
        #expect(quotedList(["甲", "乙", "丙"], more: true) == "「甲」、「乙」、「丙」和其他几项")
        #expect(Locale.interface.language.languageCode == .chinese)
        #expect(English.text("zh-Hans") == "en", "界面语言代码的英文必须是 en，列表和日期才跟着英文")
        #expect(English.text("「\("Quark")」") == "“Quark”")
        #expect(English.text("其他几项") == "others")
    }

    @Test("只查简体中文的 bundle：旁边有英文译文，取到的也是中文；界面上用的取英文")
    func simplifiedChineseBundle() throws {
        let chinese = try #require(Bundle(url: English.compiled.appending(path: "zh-Hans.lproj")))
        #expect(CompatibilityIssue.Code.loginItem.title(bundle: chinese) == "开机自启动")
        #expect(CompatibilityIssue.Code.notNotarized.detail(source: "no usable signature", bundle: chinese)
            == "没有可用的签名。打开时 macOS 会询问你是否信任它，请确认来源可靠。")
        #expect(CompatibilityIssue.Code.loginItem.title(bundle: English.bundle) == "Launch at login")
        #expect(CompatibilityIssue.Code.notNotarized.detail(source: "no usable signature", bundle: English.bundle)
            .hasPrefix("No usable signature. macOS will ask"))
    }

    @Test("语言选择存在本 App 域的 AppleLanguages 里，读得回来")
    func languageSelection() {
        // 只看换算规则，不改设置（测试进程的偏好设置域不是 MacBox 的，也别去碰）
        #expect(AppLanguage.allCases.map(\.rawValue) == ["system", "zh-Hans", "en"])
        #expect(AppLanguage.system.title == "跟随系统")
    }
}
