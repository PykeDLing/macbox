import Foundation

/// 生成本机隔离用的 Seatbelt 规则：
/// - 写：默认全部禁止，只放行盒子的主目录、临时目录、App 目录和系统临时目录（可选放行「下载」）
/// - 读：挡住其他 App 的数据、邮件信息、密钥等私人目录，以及盒子里 MacBox 自己的记录
/// - 系统服务：禁止注册登录项/后台服务、发送通知、用 Apple 事件遥控其他 App
///
/// Seatbelt 按规则先后匹配，后面的规则覆盖前面的（同一个操作名之间）
nonisolated enum SandboxProfile {
    static func make(box: BoxPaths, config: BoxConfig) -> String {
        let boxRoot = FileOps.realPath(box.url)
        let home = FileOps.realPath(AppPaths.realHome)

        var systemWritable = ["/private/var/folders", "/private/tmp", "/dev"]
        if config.shareDownloads { systemWritable.append("\(home)/Downloads") }
        // 盒子里只有这几处可写。盒子根目录下其余的是 MacBox 自己的记录：偏好设置借出的日志和本机设置的备份（Prefs）、
        // box.json、钥匙串密码、还原点。App 改了它们，MacBox 收尾时会照着改过的内容替它删改沙盒外的文件
        // （都是盒子目录的直接子项，在真实路径后面拼名字；它们可能还不存在，不能逐个解析）
        func inBox(_ url: URL) -> String { boxRoot + "/" + url.lastPathComponent }
        let boxWritable = [box.home, box.tmp, box.appDirectory].map(inBox)
        // 盒子里 App 不该看到的：本机原来的偏好设置备份（登录状态、设备 ID）、钥匙串密码、还原点
        let boxPrivate = [box.prefs, box.restorePoint].map { "(subpath \(quote(inBox($0))))" }
            + ["(literal \(quote(inBox(box.keychainPassword))))"]

        let privateReads = [
            "Library/Application Support", "Library/Containers", "Library/Group Containers",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Keychains",
            "Library/Mobile Documents", "Library/Accounts", "Library/Calendars", "Library/Biome",
            "Library/HTTPStorages", "Library/WebKit", "Library/Caches", "Library/Saved Application State",
            ".ssh", ".gnupg", ".aws", ".kube", ".config", ".netrc", ".git-credentials", ".docker", ".npmrc",
            ".codex", ".claude", ".zsh_history", ".bash_history",
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
        \(systemWritable.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))
        ; 盒子可能就在系统临时目录下（测试时），先整个挡住再放行，不依赖盒子的位置
        (deny file-write* (subpath \(quote(boxRoot))))
        (allow file-write*
        \(boxWritable.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))

        ; 只挡内容读取（file-read-data），不挡元数据：App 启动时要逐级解析自身路径
        (deny file-read-data
        \(privateReads.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))
        ; 盒子本身也在 Application Support 下，必须重新放行。
        ; 要用与拒绝规则相同的操作名：通配的 file-read* 压不过具体的 file-read-data
        (allow file-read-data (subpath \(quote(boxRoot))))
        (deny file-read-data
        \(boxPrivate.map { "  \($0)" }.joined(separator: "\n")))

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
