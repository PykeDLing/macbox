import Foundation

/// 生成本机隔离用的 Seatbelt 规则：
/// - 写：默认全部禁止，只放行盒子目录和系统临时目录（可选放行「下载」）
/// - 读：挡住其他 App 的数据、邮件信息、密钥等私人目录
/// - 系统服务：禁止注册登录项/后台服务、发送通知、用 Apple 事件遥控其他 App
nonisolated enum SandboxProfile {
    static func make(box: BoxPaths, config: BoxConfig) -> String {
        let boxRoot = FileOps.realPath(box.url)
        let home = FileOps.realPath(AppPaths.realHome)

        var writable = [boxRoot, "/private/var/folders", "/private/tmp", "/dev"]
        if config.shareDownloads { writable.append("\(home)/Downloads") }

        let privateReads = [
            "Library/Application Support", "Library/Containers", "Library/Group Containers",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Keychains",
            "Library/Mobile Documents", "Library/Accounts", "Library/Calendars", "Library/Biome",
            "Library/HTTPStorages", ".ssh", ".gnupg", ".aws", ".kube",
        ].map { "\(home)/\($0)" }

        let blockedServices = [
            "com.apple.backgroundtaskmanagement.agent", "com.apple.backgroundtaskmanagementagent",
            "com.apple.xpc.smd",
        ]

        return """
        (version 1)
        (allow default)

        (deny file-write*)
        (allow file-write*
        \(writable.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))

        ; 只挡内容读取（file-read-data），不挡元数据：App 启动时要逐级解析自身路径
        (deny file-read-data
        \(privateReads.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))
        ; 盒子本身也在 Application Support 下，必须重新放行。
        ; 要用与拒绝规则相同的操作名：通配的 file-read* 压不过具体的 file-read-data
        (allow file-read-data (subpath \(quote(boxRoot))))

        (deny appleevent-send)
        (deny mach-lookup
        \(blockedServices.map { "  (global-name \(quote($0)))" }.joined(separator: "\n"))
          (global-name-regex #"^com\\.apple\\.(usernoted|usernotifications|UNCUserNotification)"))
        \(config.isInstaller ? installerRules : "")
        """
    }

    /// 在线安装器不许挂载磁盘映像：否则它会把下载的 dmg 挂上，再经由系统从卷上启动 App（不在沙盒里）。
    /// 挂载失败后安装器会报错退出，MacBox 接手它下载好的安装包完成安装。
    private static let installerRules = """
    (deny mach-lookup (global-name-regex #"^com\\.apple\\.(DiskArbitration|diskarbitrationd)"))
    """

    private static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
