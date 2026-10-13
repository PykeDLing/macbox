import AppKit
import Foundation

nonisolated struct AppInfo: Sendable {
    let url: URL
    let name: String
    let bundleIdentifier: String
    let version: String?
    let executable: URL
}

/// 读取 App 信息，并在运行前静态检查它会不会做本机隔离挡不住的事
nonisolated enum AppInspector {
    static func info(of app: URL) throws -> AppInfo {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else {
            throw MacBoxError("「\(app.lastPathComponent)」不是有效的 App")
        }
        guard let identifier = bundle.bundleIdentifier, let executable = bundle.executableURL else {
            throw MacBoxError("「\(app.lastPathComponent)」缺少标识符或可执行文件")
        }
        let localized = bundle.localizedInfoDictionary ?? [:]
        let name = (localized["CFBundleDisplayName"] ?? localized["CFBundleName"]
            ?? info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String
        return AppInfo(url: app,
                       name: name ?? app.deletingPathExtension().lastPathComponent,
                       bundleIdentifier: identifier,
                       version: info["CFBundleShortVersionString"] as? String,
                       executable: executable)
    }

    /// Chromium / Electron 系 App：自带的子进程沙盒无法在 MacBox 的沙盒里再次建立
    static func isChromium(_ app: URL) -> Bool {
        let frameworks = app.appending(path: "Contents/Frameworks")
        let enumerator = FileManager.default.enumerator(at: frameworks, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == "chrome_crashpad_handler" || item.lastPathComponent == "Electron Framework.framework" {
                return true
            }
            if enumerator?.level ?? 0 > 6 { enumerator?.skipDescendants() }
        }
        return false
    }

    /// 启动参数：Chromium 系 App 关闭它自己的子进程沙盒（否则会反复崩溃），由 MacBox 的沙盒统一约束。
    /// 要遍历 App 包，在后台调用
    static func launchArguments(for app: URL) -> [String] { isChromium(app) ? ["--no-sandbox"] : [] }

    /// 在线安装器：名字或标识符里带 install/setup/安装
    static func looksLikeInstaller(_ info: AppInfo) -> Bool {
        let haystack = "\(info.bundleIdentifier) \(info.name) \(info.url.lastPathComponent)".lowercased()
        return ["install", "setup", "downloader", "安装"].contains { haystack.contains($0) }
    }

    /// 偏好设置域前缀：取标识符前三段，覆盖 App、安装器和各种 helper（com.quark.clouddrive.*）
    static func preferencePrefix(for identifier: String) -> String {
        identifier.split(separator: ".").prefix(3).joined(separator: ".")
    }

    @concurrent
    static func scan(_ app: URL) async -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []
        let contents = app.appending(path: "Contents")
        func has(_ relative: String) -> Bool {
            !FileOps.contents(of: contents.appending(path: relative)).isEmpty
        }

        if has("Library/LaunchServices") || Bundle(url: app)?.object(forInfoDictionaryKey: "SMPrivilegedExecutables") != nil {
            issues.append(.init(severity: .needsVirtualMac, title: "需要管理员权限的辅助程序",
                                detail: "会以 root 身份在系统里安装常驻服务，本机隔离无法容纳。"))
        }
        if has("Library/LaunchDaemons") {
            issues.append(.init(severity: .needsVirtualMac, title: "系统级后台服务",
                                detail: "会注册开机即运行的系统服务。"))
        }
        if has("Library/SystemExtensions") || containsItem(in: contents, withExtensions: ["kext", "systemextension"]) {
            issues.append(.init(severity: .needsVirtualMac, title: "系统扩展或内核扩展",
                                detail: "需要加载到系统内核或系统扩展框架中。"))
        }
        if FileOps.contents(of: contents.appending(path: "PlugIns")).contains(where: { $0.pathExtension == "driver" }) {
            issues.append(.init(severity: .needsVirtualMac, title: "硬件或音频驱动",
                                detail: "驱动需要安装到系统目录。"))
        }
        if has("Library/LoginItems") || has("Library/LaunchAgents") {
            issues.append(.init(severity: .limited, title: "开机自启动",
                                detail: "自启动项会被阻止，只有你打开时它才运行。"))
        }
        for appex in FileOps.contents(of: contents.appending(path: "PlugIns")) where appex.pathExtension == "appex" {
            let point = Bundle(url: appex)?.object(forInfoDictionaryKey: "NSExtension")
                .flatMap { ($0 as? [String: Any])?["NSExtensionPointIdentifier"] as? String } ?? ""
            if point.contains("FinderSync") || point.contains("fileprovider") {
                issues.append(.init(severity: .limited, title: "访达集成",
                                    detail: "同步状态图标、右键菜单等访达扩展不可用。"))
                break
            }
        }

        let entitlements = (try? await Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path]))?.output ?? ""
        if entitlements.contains("com.apple.developer.networking.networkextension") {
            issues.append(.init(severity: .needsVirtualMac, title: "网络扩展",
                                detail: "VPN、代理等网络扩展需要系统级安装。"))
        }
        if entitlements.contains("com.apple.security.app-sandbox") {
            issues.append(.init(severity: .info, title: "自带苹果沙盒",
                                detail: "在 MacBox 中它改由 MacBox 的沙盒约束，数据存进盒子；请经由 MacBox 打开它。"))
        }
        return issues
    }

    /// 用 Gatekeeper 同样的规则检查 App：通过公证的，去掉盒子里副本的“来自互联网”标记，
    /// 免得系统在 MacBox 已经确认过之后再弹一次“确定要打开吗”；没通过的保留标记，由系统拦下
    static func verifyAndTrust(_ app: URL) async -> CompatibilityIssue {
        let result = try? await Shell.execute("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        let text = (result?.output ?? "") + (result?.error ?? "")
        func field(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        if result?.status == 0 {
            _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            return CompatibilityIssue(severity: .info, title: "已通过 Apple 公证检查",
                                      detail: field("origin") ?? field("source") ?? "来源已验证")
        }
        return CompatibilityIssue(severity: .limited, title: "未通过 Apple 公证检查",
                                  detail: "\(field("source") ?? "签名无效")。打开时 macOS 会询问你是否信任它，请确认来源可靠。")
    }

    private static func containsItem(in directory: URL, withExtensions extensions: Set<String>) -> Bool {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let item = enumerator?.nextObject() as? URL {
            if extensions.contains(item.pathExtension) { return true }
            if item.pathExtension == "framework" { enumerator?.skipDescendants() }
        }
        return false
    }
}
