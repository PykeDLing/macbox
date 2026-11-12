import Foundation
import Testing
@testable import MacBox

/// 检查更新里不联网的部分：比较版本号、读 GitHub 的回答、多久问一次；以及反馈表单的地址
@Suite("检查更新")
struct UpdateCheckerTests {
    @Test("版本号按数字逐段比较：0.4.10 比 0.4.9 新，少的段当 0，读不出数字的不算新", arguments: [
        ("0.4.5", "0.4.4", true), ("0.4.10", "0.4.9", true), ("0.5", "0.4.9", true), ("1.0.0", "0.9.9", true),
        ("0.4.4", "0.4.4", false), ("0.4.4", "0.4.5", false), ("0.4", "0.4.0", false), ("0.4.0.1", "0.4", true),
        ("0.4.5-beta", "0.4.4", false), ("", "0.4.4", false), ("latest", "0.4.4", false), ("0.4.5", "dev", false),
    ])
    func comparing(candidate: String, current: String, newer: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == newer)
    }

    @Test("GitHub 的回答：取版本号和发布页；发布页不是本仓库的就退回固定的那一页；读不懂的报错")
    func parsing() throws {
        func release(_ object: [String: Any]) throws -> UpdateChecker.Release {
            try UpdateChecker.release(from: JSONSerialization.data(withJSONObject: object))
        }
        let page = "https://github.com/PykeDLing/macbox/releases/tag/v0.4.5"
        #expect(try release(["tag_name": "v0.4.5", "html_url": page, "draft": false])
                == UpdateChecker.Release(version: "0.4.5", page: URL(string: page)!))
        #expect(try release(["tag_name": "0.5.0"]).page == UpdateChecker.releasesPage, "没有发布页")
        for elsewhere in ["https://example.com/PykeDLing/macbox/releases/tag/v9", "http://github.com/PykeDLing/macbox/releases/tag/v9",
                          "https://github.com/someone/else/releases/tag/v9", "https://github.com.evil.example/PykeDLing/macbox/releases/"] {
            #expect(try release(["tag_name": "v9.0.0", "html_url": elsewhere]).page == UpdateChecker.releasesPage, "\(elsewhere)")
        }
        #expect(throws: (any Error).self) { try release(["name": "no tag"]) }
        #expect(throws: (any Error).self) { try release(["tag_name": "nightly"]) }
        #expect(throws: (any Error).self) { try UpdateChecker.release(from: Data("<html>rate limited</html>".utf8)) }
    }

    @Test("自动检查每天最多一次；没查过、时钟被往回拨过都算到期")
    func due() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateChecker.isDue(last: nil, now: now))
        #expect(!UpdateChecker.isDue(last: now.addingTimeInterval(-3600), now: now))
        #expect(!UpdateChecker.isDue(last: now.addingTimeInterval(-23.9 * 3600), now: now))
        #expect(UpdateChecker.isDue(last: now.addingTimeInterval(-24 * 3600), now: now))
        #expect(UpdateChecker.isDue(last: now.addingTimeInterval(3600), now: now), "上次在将来")
    }

    @Test("试用、测试用的数据目录下不自动检查", .enabled(if: AppPaths.override != nil, "需要 MACBOX_DATA_ROOT"))
    @MainActor
    func noAutomaticCheckOnTestData() {
        let checker = UpdateChecker()
        let before = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date
        checker.checkAutomaticallyIfDue(now: Date(timeIntervalSinceNow: 10 * 24 * 3600))
        #expect(checker.state == .idle)
        #expect(UserDefaults.standard.object(forKey: UpdateChecker.lastCheckKey) as? Date == before)
    }

    @Test("反馈表单的地址：只带表单名、MacBox 和 macOS 的版本，空格和括号编好码")
    func reportLinks() throws {
        let url = Links.report(.compatibility, version: "0.4.5", system: "27.2 (26B123)")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com" && components.path == "/PykeDLing/macbox/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["template": "compatibility.yml", "macbox": "0.4.5", "macos": "27.2 (26B123)"])
        #expect(!url.absoluteString.contains(" "))
        #expect(Links.report(.bug).absoluteString.contains("template=bug.yml"))
        #expect(Links.systemVersion.first?.isNumber == true)
        // 表单里要有这两个字段，名字对不上的话填好的版本号就丢了
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for form in ["bug", "compatibility"] {
            let text = try String(contentsOf: root.appending(path: ".github/ISSUE_TEMPLATE/\(form).yml"), encoding: .utf8)
            #expect(text.contains("id: macbox") && text.contains("id: macos"), "\(form).yml")
        }
    }
}
