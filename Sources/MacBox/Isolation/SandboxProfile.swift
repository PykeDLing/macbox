import Foundation

/// 生成本机隔离用的 Seatbelt 规则：
/// - 写：默认全部禁止，只放行盒子的主目录、临时目录、App 目录和系统临时目录（可选放行「下载」）
/// - 读：挡住其他 App 的数据、邮件信息、密钥等私人目录，以及盒子里 MacBox 自己的记录
/// - 系统服务：禁止注册登录项/后台服务、发送通知、用 Apple 事件遥控其他 App
/// - 网络：默认放行，可以按应用关掉（见 offlineRules）
/// - 启动程序、写共享的「下载」：放行，但每次都在系统日志里记一笔，运行报告据此列出它启动了哪些程序、在「下载」里写了什么
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
        // 盒子里只有这几处可写。盒子根目录下其余的是 MacBox 自己的记录：偏好设置借出的日志和本机设置的备份（Prefs）、
        // box.json、钥匙串密码、还原点、运行报告。App 改了它们，MacBox 收尾时会照着改过的内容替它删改沙盒外的文件
        // （都是盒子目录的直接子项，在真实路径后面拼名字；它们可能还不存在，不能逐个解析）
        func inBox(_ url: URL) -> String { boxRoot + "/" + url.lastPathComponent }
        let boxWritable = [box.home, box.tmp, box.appDirectory].map(inBox)
        // 可写的只是这几个文件夹里面，文件夹本身不能删、不能改名、不能换成符号链接：
        // subpath 也包括它自己，App 可以清空 App 文件夹后 rmdir，再在原处放一个指向 /Applications 的链接，
        // MacBox 在沙盒外上锁、解锁、找安装包、准备主目录时就会顺着链接改到别处（去掉你自己装的同名 App 的执行权限、
        // 把你真实的「下载」移走）。主目录里的 Library、Library/Keychains 同理：MacBox 每次启动前会在里面
        // 替换 login.keychain-db，顺着链接替换的会是你自己的「登录」钥匙串
        let boxSkeleton = boxWritable + ["Library", "Library/Keychains"].map { inBox(box.home) + "/" + $0 }
        // 盒子里 App 不该看到的：本机原来的偏好设置备份（登录状态、设备 ID）、钥匙串密码、还原点，
        // 以及运行报告（记着它以前每次运行写了什么、连了哪里，不该由它来读）
        let boxPrivate = [box.prefs, box.restorePoint, box.reports].map { "(subpath \(quote(inBox($0))))" }
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
        ; 照常放行，只是每启动一个程序都在系统日志里记一笔（运行报告的“启动了哪些程序”，见 ViolationMonitor）
        (allow process-exec (with report))

        (deny file-write*)
        (allow file-write*
        \(systemWritable.map { "  (subpath \(quote($0)))" }.joined(separator: "\n")))
        \(downloadsRule)
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
