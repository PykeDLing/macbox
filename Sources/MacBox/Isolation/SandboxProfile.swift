import Foundation

/// 生成本机隔离用的 Seatbelt 规则：
/// - 写：默认全部禁止，只放行盒子的主目录、临时目录、App 目录和系统临时目录（可选放行「下载」和你选的文件夹）
/// - 读：挡住其他 App 的数据、邮件信息、密钥等私人目录，以及盒子里 MacBox 自己的记录
/// - 系统服务：禁止注册登录项/后台服务、发送通知、用 Apple 事件遥控其他 App
/// - 网络：默认放行，可以按应用关掉（见 offlineRules）
/// - 启动程序、写共享的「下载」和你选的文件夹：放行，但每次都在系统日志里记一笔，运行报告据此列出它启动了哪些程序、在盒子外写了什么
///
/// Seatbelt 按规则先后匹配，后面的规则覆盖前面的（同一个操作名之间）
nonisolated enum SandboxProfile {
    static func make(box: BoxPaths, config: BoxConfig) -> String {
        let boxRoot = FileOps.realPath(box.url)
        let home = FileOps.realPath(AppPaths.realHome)

        let systemWritable = ["/private/var/folders", "/private/tmp", "/dev"]
        // 共享时放行写你的「下载」，并且每次写都在系统日志里记一笔：运行报告靠它知道应用在里面写了什么。
        // MacBox 自己不去读「下载」：那要你在系统设置里授权，第一次会弹窗问，还分不出哪些是你自己放的
        let downloadsRule = config.shareDownloads ? "(allow file-write* (subpath \(quote("\(home)/Downloads"))) (with report))" : ""
        // 你选的可以写入的文件夹，同样每次写都记一笔。存的是选的时候解析出的真实路径，原样使用、不再解析（见 WritableFolders）
        let folderRules = WritableFolders.granted(config).map { "(allow file-write* (subpath \(quote($0))) (with report))" }
        // 盒子里哪些可写、哪些不能删改、哪些读不到，见 BoxPaths 的分类。
        // 在盒子的真实路径后面拼上相对盒子的路径：它们可能还不存在，不能逐个解析
        func inBox(_ url: URL) -> String { boxRoot + url.path.dropFirst(box.url.path.count) }
        let boxWritable = box.writableItems.map(inBox)
        let boxSkeleton = box.skeleton.map(inBox)
        let boxPrivate = box.privateItems.map { "(\($0.hasDirectoryPath ? "subpath" : "literal") \(quote(inBox($0))))" }

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
        ; 照常放行，只是每启动一个程序都在系统日志里记一笔（运行报告的“启动了哪些程序”，见 ViolationMonitor）
        (allow process-exec (with report))

        (deny file-write*)
        (allow file-write*
        \(systemWritable.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))
        \(downloadsRule)
        \(folderRules.joined(separator: "\n"))
        ; 选的文件夹和盒子重叠时（检查过，不该有）也以盒子自己的规则为准：它们在后面。
        ; 盒子可能就在系统临时目录下（测试时），先整个挡住再放行，不依赖盒子的位置
        (deny file-write* (subpath \(quote(boxRoot))))
        (allow file-write*
        \(boxWritable.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))
        (deny file-write*
        \(boxSkeleton.map { "  (literal \(quote($0)))" }.joined(separator: "\n")))

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
        \(config.allowsNetwork ? "" : offlineRules)
        """
    }

    /// 在线安装器不许挂载磁盘映像：否则它会把下载的 dmg 挂上，再经由系统从卷上启动 App（不在沙盒里）。
    /// 挂载失败后安装器会报错退出，MacBox 接手它下载好的安装包完成安装。
    private static let installerRules = """
    (deny mach-lookup (global-name-regex #"^com\\.apple\\.(DiskArbitration|diskarbitrationd)"))
    """

    /// 不联网。只挡应用自己的连接不够，实测还有三条路：
    /// - 本机上的代理：系统设置了代理时，URLSession、Chromium 都先连 127.0.0.1 上的代理端口，由代理替它出去。
    ///   所以回环地址一样挡（用回环地址在自己的进程之间通信的应用会受影响）；
    /// - 域名解析：由 mDNSResponder 代查，挡住才不会“连不上却能查询”，应用也能很快失败而不是一直重试；
    /// - 替它联网的系统进程：WKWebView 的网页由 WebKit 的网络进程加载，它由 launchd 启动、不在盒子的沙盒里，
    ///   只挡应用自己的话网页照样打得开。不许它启动这个进程，网页视图就加载不了任何内容（本地网页也不行）；
    ///   后台 URLSession 的下载由 nsurlsessiond 代做，同理。
    /// 也不许等别人连进来（network-inbound 包括 bind、listen），免得局域网里的设备连上它来取数据
    private static let offlineRules = """
    (deny network-outbound (remote ip))
    (deny network-inbound (local ip))
    (deny network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
    (deny mach-lookup
      (global-name "com.apple.dnssd.service")
      (global-name-regex #"^com\\.apple\\.nsurlsessiond")
      (xpc-service-name-regex #"^com\\.apple\\.WebKit\\.Networking"))
    """

    private static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
