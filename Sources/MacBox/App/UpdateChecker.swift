import AppKit
import Foundation
import Observation

/// 检查更新：只向 GitHub 问一句“最新发布的是哪个版本”，有新版就告诉你、带你去下载页。不下载、不安装、不上传任何东西。
///
/// MacBox 没有公证，也就没有自动更新这回事：新版本要你自己下载、替换。不提醒的话，装过一次的人会一直停在旧版。
/// 自动检查每天最多一次（打开 MacBox 时），可以在设置里关掉；菜单里的「检查更新…」随时可以点。
/// 试用、测试用的数据目录（MACBOX_DATA_ROOT）下不自动检查
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    nonisolated struct Release: Equatable, Sendable {
        /// 版本号，不带开头的 v
        let version: String
        /// 这一版的发布页
        let page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// 设置里的「自动检查更新」，默认打开
    nonisolated static let automaticKey = "checksForUpdates"
    /// 上次自动检查的时间
    nonisolated static let lastCheckKey = "lastUpdateCheck"
    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/PykeDLing/macbox/releases/latest")!
    nonisolated static let releasesPage = URL(string: "https://github.com/PykeDLing/macbox/releases/latest")!

    private(set) var state: State = .idle
    /// 手动检查的结果要告诉你（见 MainView）；自动检查只在侧边栏里留一行
    var announcement: Announcement?

    nonisolated struct Announcement: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
        /// 有新版时带你去的页面
        let page: URL?
    }

    var available: Release? {
        if case .available(let release) = state { release } else { nil }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static var checksAutomatically: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    /// 打开 MacBox 时：开着自动检查、距上次满一天才问
    func checkAutomaticallyIfDue(now: Date = Date()) {
        guard AppPaths.override == nil, Self.checksAutomatically,
              Self.isDue(last: UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date, now: now) else { return }
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        Task { await check(userInitiated: false) }
    }

    nonisolated static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        // 时钟被往回拨过（上次在“将来”）也算到期
        return now.timeIntervalSince(last) >= 24 * 3600 || last > now
    }

    /// 问一次。userInitiated：你点的「检查更新…」，结果无论如何都告诉你；自动检查失败、没有新版时不出声
    func check(userInitiated: Bool) async {
        guard state != .checking else { return }
        let previous = state
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            if Self.isNewer(release.version, than: Self.currentVersion) {
                state = .available(release)
                if userInitiated {
                    announcement = Announcement(
                        title: String(localized: "有新版本：MacBox \(release.version)"),
                        message: String(localized: "你现在用的是 \(Self.currentVersion)。新版本要在发布页下载，退出 MacBox 后替换「应用程序」里的那一份；盒子和里面的数据都会保留。"),
                        page: release.page)
                }
            } else {
                state = .upToDate
                if userInitiated {
                    announcement = Announcement(title: String(localized: "已经是最新版本"),
                                                message: String(localized: "MacBox \(Self.currentVersion) 是目前最新的版本。"), page: nil)
                }
            }
        } catch {
            // 自动检查失败不留痕迹：之前查到的新版本照旧显示
            state = userInitiated ? .failed(error.localizedDescription) : previous
            if userInitiated {
                announcement = Announcement(title: String(localized: "无法检查更新"),
                                            message: String(localized: "没能连上 GitHub：\(error.localizedDescription)"),
                                            page: nil)
            }
        }
    }

    func openDownloadPage(_ page: URL? = nil) {
        NSWorkspace.shared.open(page ?? available?.page ?? Self.releasesPage)
    }

    // MARK: - 请求与解析

    /// 不带 Cookie、不留缓存；除了 GitHub 的接口要求的 User-Agent（MacBox 和版本号）不带任何信息
    private nonisolated static func fetchLatest() async throws -> Release {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacBox/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MacBoxError(String(localized: "GitHub 返回了 \(String(code))"))
        }
        return try release(from: data)
    }

    /// GitHub 的 releases/latest：tag_name 是 “v0.4.5”，html_url 是发布页。
    /// 发布页只认本仓库的：接口返回别的地址（被改过、被劫持）时退回固定的发布页，不带你去别处
    nonisolated static func release(from data: Data) throws -> Release {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw MacBoxError(String(localized: "读不懂 GitHub 返回的内容"))
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !components(of: version).isEmpty else { throw MacBoxError(String(localized: "读不懂 GitHub 返回的内容")) }
        let page = (object["html_url"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" && url.host() == "github.com" && url.path().hasPrefix("/PykeDLing/macbox/releases/") ? url : nil
        }
        return Release(version: version, page: page ?? releasesPage)
    }

    /// 版本号按数字逐段比较（0.4.10 比 0.4.9 新），少的段当 0；读不出数字的版本不算新
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(of: candidate), b = components(of: current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// “0.4.5” → [0, 4, 5]。有一段不是数字（“0.4.5-beta”）时整个读不出
    private nonisolated static func components(of version: String) -> [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }
}
