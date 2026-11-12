import Foundation

/// MacBox 在网上的几个地方：网站、兼容清单、反馈问题。都在浏览器里打开，MacBox 自己不去访问
nonisolated enum Links {
    static let website = URL(string: "https://pykedling.github.io/macbox/")!
    static let compatibility = URL(string: "https://github.com/PykeDLing/macbox/blob/main/docs/compatibility.md")!
    private static let newIssue = "https://github.com/PykeDLing/macbox/issues/new"

    /// 反馈的两种表单（见 .github/ISSUE_TEMPLATE）
    enum Report: String {
        /// MacBox 自己的问题
        case bug
        /// 某个应用放进 MacBox 之后能不能用
        case compatibility
    }

    /// 新建一条反馈的地址，替你填好 MacBox 和 macOS 的版本：这两样每次都要问，自己查又麻烦。
    /// 只带这两个版本号，别的（盒子里有什么应用、运行报告）要你自己决定写不写
    static func report(_ kind: Report, version: String = UpdateChecker.currentVersion, system: String = systemVersion) -> URL {
        var components = URLComponents(string: newIssue)!
        components.queryItems = [
            URLQueryItem(name: "template", value: "\(kind.rawValue).yml"),
            URLQueryItem(name: "macbox", value: version),
            URLQueryItem(name: "macos", value: system),
        ]
        return components.url!
    }

    /// “27.2 (26B123)”
    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
                                               : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var build = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &build, &size, nil, 0)
        let name = String(decoding: build.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return name.isEmpty ? number : "\(number) (\(name))"
    }
}
