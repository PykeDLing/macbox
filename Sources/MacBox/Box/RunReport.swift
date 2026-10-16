import Darwin
import Foundation

/// 运行期间陆续得到的记录（见 IsolatedSession.run 的 onActivity）
nonisolated enum RunActivity: Sendable {
    /// 被挡住的行为
    case blocked(BlockEvent)
    /// 启动了一个程序（可执行文件路径，原样）
    case launched(String)
    /// 第一次看到连到某个服务器
    case connected(ServerContact)
    /// 服务器的地址反向解析出了名字
    case named(address: String, name: String)
    /// 在共享的「下载」里写了东西（路径原样，操作是沙盒的操作名：file-write-create、file-write-unlink……）
    case wroteDownload(path: String, operation: String)
}

/// 一次本机隔离运行的报告：写了哪些文件、改了哪些设置、连了哪些服务器、启动了哪些程序、哪些行为被拦下。
///
/// 连接、程序在运行期间陆续记下（见 Box.record），文件和设置在所有进程退出后对比运行前后得出（见 RunSnapshot），
/// 拦截记录在收尾时从 Box.blocks 抄过来。之后存进盒子的 Reports 文件夹（App 读不到也改不了，见 SandboxProfile）。
/// 路径都写成应用眼里的样子、不带你的用户名（见 PathTidier），可以直接导出分享。
/// 字段只增不改；新增字段必须是可选类型，旧报告才能照常读取
nonisolated struct RunReport: Codable, Identifiable, Sendable {
    var id = UUID()
    var appName: String
    var version: String?
    var bundleIdentifier: String
    var startedAt = Date()
    /// 所有进程都退出的时间；运行中为 nil
    var endedAt: Date?
    var networkBlocked: Bool
    var sharesDownloads: Bool
    /// 写下的文件，按位置汇总（最多 maxAreas 处）。nil：还在运行，或者没能统计
    var files: [FileArea]?
    /// 全部位置的合计（files 只留了改动最多的几处）
    var fileTotals: FileTotals?
    /// 偏好设置的改动。nil：还在运行，或者设置没能收回、比不出来
    var preferences: [PreferenceChange]?
    var servers: [ServerContact] = []
    var programs: [ProgramLaunch] = []
    var blocks: [BlockEvent] = []

    /// 一份报告最多列出多少处文件位置
    static let maxAreas = 200
    /// 每个盒子留几份报告
    static let kept = 20

    init(config: BoxConfig) {
        appName = config.name
        version = config.version
        bundleIdentifier = config.bundleIdentifier
        networkBlocked = !config.allowsNetwork
        sharesDownloads = config.shareDownloads
    }

    var isRunning: Bool { endedAt == nil }
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    /// 被拦下的总次数
    var blockCount: Int { blocks.reduce(0) { $0 + $1.count } }
    /// 改了多少项设置
    var preferenceKeyCount: Int? { preferences?.reduce(0) { $0 + $1.added.count + $1.changed.count + $1.removed.count } }

    mutating func noteLaunch(_ path: String) {
        if let index = programs.firstIndex(where: { $0.path == path }) {
            programs[index].count += 1
        } else {
            programs.append(ProgramLaunch(path: path))
        }
    }

    mutating func note(_ contact: ServerContact) {
        guard !servers.contains(where: { $0.id == contact.id }) else { return }
        servers.append(contact)
    }

    mutating func name(_ address: String, _ name: String) {
        for index in servers.indices where servers[index].address == address { servers[index].name = name }
    }
}

nonisolated struct FileTotals: Codable, Hashable, Sendable {
    var created = 0
    var modified = 0
    var deleted = 0
    /// 新建、修改的文件现在的大小
    var bytes: Int64 = 0

    var count: Int { created + modified + deleted }
}

/// 一处位置（一个文件夹或一个文件）里的改动
nonisolated struct FileArea: Codable, Hashable, Identifiable, Sendable {
    nonisolated enum Location: String, Codable, Sendable {
        /// 应用的主目录（在盒子里，应用眼里就是 ~）
        case home
        /// 应用本身（App 包里的文件：自动更新、自己改写自己）
        case app
        /// 你真实的「下载」（共享时）
        case downloads
    }

    var location: Location
    /// 应用眼里的位置：~/Library/Application Support/X、X.app/Contents/Resources、~/Downloads/x.dmg
    var path: String
    var totals = FileTotals()
    /// 几个新建或修改的文件（相对 path），最多 3 个
    var examples: [String] = []
    var id: String { path }
}

/// 一个偏好设置域里的改动（只记键名，不记内容：值里常有登录凭证、设备 ID）
nonisolated struct PreferenceChange: Codable, Hashable, Identifiable, Sendable {
    var domain: String
    /// 运行前盒子里没有这个域
    var isNew: Bool
    var added: [String]
    var changed: [String]
    var removed: [String]
    var id: String { domain }
}

/// 连到过的一个服务器
nonisolated struct ServerContact: Codable, Hashable, Identifiable, Sendable {
    /// IP 地址（IPv6 不带方括号）
    var address: String
    var port: Int
    /// tcp、udp 或 quic（HTTP/3）
    var transport: String
    /// 反向解析出的名字（常常是云服务商的机器名）；解析不出时为 nil
    var name: String?
    /// 第一次看到时是哪个进程连的
    var process: String?
    var firstSeen = Date()
    var id: String { "\(transport) \(address) \(port)" }

    nonisolated enum Scope: Sendable {
        /// 本机（127.0.0.1、::1）：多半是本机上的代理，或者应用自己的进程之间通信
        case loopback
        /// 局域网里的设备
        case localNetwork
        /// 局域网广播、组播（查找打印机、投屏设备等）
        case multicast
        /// 代理软件的“虚拟 IP”模式分配的地址（198.18.0.0/15），真实的服务器只有代理知道
        case proxyMapped
        case internet
    }

    var scope: Scope {
        if address.contains(":") {
            let lower = address.lowercased()
            if lower == "::1" { return .loopback }
            if lower.hasPrefix("ff") { return .multicast }
            if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb")
                || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return .localNetwork }
            if lower.hasPrefix("::ffff:") { return ServerContact(address: String(lower.dropFirst(7)), port: port, transport: transport).scope }
            return .internet
        }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return .internet }
        switch (octets[0], octets[1]) {
        case (127, _): return .loopback
        case (10, _), (192, 168), (169, 254): return .localNetwork
        case (172, 16...31): return .localNetwork
        case (198, 18...19): return .proxyMapped
        case (224...239, _), (255, 255): return .multicast
        default: return .internet
        }
    }

    /// 列表里显示的名字：反向解析出的名字，没有时按地址的类别说明
    var title: String {
        if let name { return name }
        switch scope {
        case .loopback: return L("本机（可能是代理）", "This Mac (possibly a proxy)")
        case .localNetwork: return L("局域网里的设备", "A device on your local network")
        case .multicast: return L("局域网广播（查找设备）", "Local network broadcast (device discovery)")
        case .proxyMapped: return L("代理分配的地址（真实服务器未知）", "Proxy-assigned address (real server unknown)")
        case .internet: return address
        }
    }

    /// 地址和端口：IPv6 加方括号
    var endpoint: String { address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)" }

    /// 跟在 title 旁边的：title 已经是地址了（公网地址、没解析出名字）就只写端口，免得把地址写两遍
    var place: String { name == nil && scope == .internet ? L("端口 \(port)", "port \(port)") : endpoint }
}

/// 启动过的一个程序
nonisolated struct ProgramLaunch: Codable, Hashable, Identifiable, Sendable {
    /// 应用眼里的路径（见 PathTidier）：App 包里的写成 X.app/…，主目录里的写成 ~/…，系统程序原样
    var path: String
    var count = 1
    var firstSeen = Date()
    var id: String { path }

    /// 这个程序是做什么的：应用自己的、它放在主目录里的、常见的系统工具。其余为 nil
    var note: String? {
        if path.hasPrefix("~/") { return L("应用放在主目录里的程序（下载或解压出来的）", "A program the app put in its home folder (downloaded or unpacked)") }
        if !path.hasPrefix("/") { return L("应用自己的程序", "The app’s own program") }
        return Self.systemNotes[path].map { L($0.0, $0.1) }
    }

    /// 常见的系统工具。说的是这个工具能做什么，不是应用拿它做了什么（参数没有记下）
    private static let systemNotes: [String: (String, String)] = [
        "/usr/sbin/ioreg": ("读取硬件信息，可以拿到序列号、硬件 UUID", "Reads hardware info, which can include the serial number and hardware UUID"),
        "/usr/sbin/system_profiler": ("读取系统和硬件的详细信息", "Reads detailed system and hardware info"),
        "/usr/sbin/sysctl": ("读取系统参数（型号、处理器等）", "Reads system parameters (model, processor and so on)"),
        "/sbin/ifconfig": ("读取网卡信息，包括 MAC 地址", "Reads network interfaces, including MAC addresses"),
        "/usr/sbin/networksetup": ("读取或修改网络设置", "Reads or changes network settings"),
        "/usr/sbin/scutil": ("读取系统配置（电脑名称、代理、DNS）", "Reads system configuration (computer name, proxies, DNS)"),
        "/usr/sbin/arp": ("读取局域网里其他设备的地址", "Reads addresses of other devices on the local network"),
        "/usr/bin/sw_vers": ("读取 macOS 版本", "Reads the macOS version"),
        "/usr/bin/uname": ("读取系统版本和架构", "Reads the system version and architecture"),
        "/usr/bin/whoami": ("读取你的用户名", "Reads your user name"),
        "/usr/bin/id": ("读取你的用户名和用户组", "Reads your user name and groups"),
        "/bin/launchctl": ("管理后台服务和登录项", "Manages background services and login items"),
        "/usr/bin/osascript": ("运行 AppleScript / JavaScript 脚本", "Runs AppleScript or JavaScript"),
        "/usr/bin/security": ("访问钥匙串和证书", "Accesses the keychain and certificates"),
        "/usr/bin/defaults": ("读写偏好设置", "Reads or writes preferences"),
        "/usr/bin/plutil": ("读写属性列表文件", "Reads or writes property list files"),
        "/bin/ps": ("列出正在运行的程序", "Lists running programs"),
        "/usr/bin/pgrep": ("查找正在运行的程序", "Looks for running programs"),
        "/usr/bin/pkill": ("结束其他程序", "Ends other programs"),
        "/usr/bin/killall": ("结束其他程序", "Ends other programs"),
        "/bin/kill": ("结束其他程序", "Ends other programs"),
        "/usr/sbin/lsof": ("列出打开的文件和网络连接", "Lists open files and network connections"),
        "/usr/bin/curl": ("下载或上传数据", "Downloads or uploads data"),
        "/usr/bin/open": ("打开文件、网址或其他 App", "Opens files, URLs or other apps"),
        "/usr/bin/codesign": ("检查程序签名", "Checks code signatures"),
        "/usr/sbin/spctl": ("查询 Gatekeeper 的设置", "Queries Gatekeeper settings"),
        "/usr/bin/xattr": ("读写文件的扩展属性（比如去掉下载标记）", "Reads or writes extended attributes (for example, removes the download quarantine flag)"),
        "/usr/bin/hdiutil": ("挂载磁盘映像", "Mounts disk images"),
        "/usr/sbin/diskutil": ("读取磁盘信息", "Reads disk info"),
        "/usr/bin/mdfind": ("用聚焦搜索文件", "Searches files with Spotlight"),
        "/usr/bin/ditto": ("复制、解压文件", "Copies or unpacks files"),
        "/usr/bin/unzip": ("解压文件", "Unpacks files"),
        "/bin/rm": ("删除文件", "Deletes files"),
        "/bin/sh": ("运行 shell 脚本或命令", "Runs a shell script or command"),
        "/bin/bash": ("运行 shell 脚本或命令", "Runs a shell script or command"),
        "/bin/zsh": ("运行 shell 脚本或命令", "Runs a shell script or command"),
        "/usr/bin/python3": ("运行 Python 脚本", "Runs a Python script"),
        "/usr/bin/perl": ("运行 Perl 脚本", "Runs a Perl script"),
    ]
}

/// 把路径写成应用眼里的样子、去掉你的用户名：盒子的主目录、你的主目录都写成 ~，盒子里的 App 写成 App 包名开头，
/// 盒子的临时文件夹写成 $TMPDIR（应用的环境变量）。导出、分享的报告里不会带出你的用户名和盒子的位置
nonisolated struct PathTidier: Sendable {
    private let replacements: [(prefix: String, replacement: String)]

    init(paths: BoxPaths) {
        let boxRoot = FileOps.realPath(paths.url)
        func inBox(_ url: URL) -> String { boxRoot + "/" + url.lastPathComponent + "/" }
        // 长的在前：盒子在你的主目录下面
        replacements = [
            (inBox(paths.home), "~/"),
            (inBox(paths.appDirectory), ""),
            (inBox(paths.tmp), "$TMPDIR/"),
            (FileOps.realPath(AppPaths.realHome) + "/", "~/"),
        ]
    }

    func callAsFunction(_ path: String) -> String {
        for (prefix, replacement) in replacements where path.hasPrefix(prefix) {
            return replacement + path.dropFirst(prefix.count)
        }
        return path
    }

    func callAsFunction(_ event: BlockEvent) -> BlockEvent {
        BlockEvent(kind: event.kind, target: self(event.target), count: event.count, lastSeen: event.lastSeen)
    }
}

// MARK: - 运行前后对比

/// 这次运行的改动：对比运行前后得出
nonisolated struct RunChanges: Sendable {
    var files: [FileArea]
    var fileTotals: FileTotals
    /// 偏好设置没能收回时为 nil：盒子里存的还是运行前的内容，比不出来
    var preferences: [PreferenceChange]?
}

/// 运行前的样子：主目录、App 里的每个文件（大小、修改时间、inode），盒子保存的偏好设置。
/// 退出后和那时的样子对比，得出这次写了哪些文件、改了哪些设置。
///
/// 只对比盒子里的，不看 /private/tmp、/private/var/folders：那里是所有程序共用的，分不出是谁写的。
/// 共享的「下载」不对比（MacBox 读它要你授权），按系统日志里的写入记录推断（见 DownloadWrites）
nonisolated struct RunSnapshot: Sendable {
    struct Entry: Equatable, Sendable {
        let size: Int64
        let modified: TimeInterval
        let inode: UInt64
    }

    /// 主目录、App 里的文件
    struct Files: Sendable {
        let home: [String: Entry]
        let app: [String: Entry]
    }

    let files: Files
    /// 盒子保存的偏好设置：域 → 键 → 值（XML 格式，键按字母排序，同样的值得到同样的内容）
    let preferences: [String: [String: Data]]

    /// 记下文件。在 MacBox 准备好主目录和钥匙串之后调用，它自己的改动不算到应用头上。
    /// 文件多的 App 要走一会儿（实测 4.7 万个文件约半秒），启动时和借出偏好设置、等日志流同时做
    @concurrent
    static func files(of paths: BoxPaths, config: BoxConfig) async -> Files {
        Files(home: entries(under: paths.home), app: entries(under: paths.appDirectory))
    }

    /// 记下盒子保存的偏好设置。借出不改它们（收回时才写回），在借出之后记：
    /// 借出前要是先收回了上次没收回的，收回会改写它们，那不是这次运行的改动
    @concurrent
    static func savedPreferences(of paths: BoxPaths, config: BoxConfig) async -> [String: [String: Data]] {
        preferences(in: paths.prefs, prefixes: config.preferencePrefixes)
    }

    /// 一次记下全部（测试用；运行时分两步，见 IsolatedSession.run）
    static func take(_ paths: BoxPaths, config: BoxConfig) async -> RunSnapshot {
        RunSnapshot(files: await files(of: paths, config: config), preferences: await savedPreferences(of: paths, config: config))
    }

    /// 和现在对比。在收回偏好设置之后调用；没能收回时 preferencesReturned 为 false。
    /// downloads：共享的「下载」里的改动（见 DownloadWrites），一起汇总
    @concurrent
    func changes(_ paths: BoxPaths, config: BoxConfig, preferencesReturned: Bool, downloads: [FileArea] = []) async -> RunChanges {
        var areas: [String: FileArea] = [:]
        Self.collect(before: files.home, after: Self.entries(under: paths.home), location: .home, into: &areas)
        Self.collect(before: files.app, after: Self.entries(under: paths.appDirectory), location: .app, into: &areas)
        for area in downloads { areas[area.path] = area }
        var totals = FileTotals()
        for area in areas.values {
            totals.created += area.totals.created
            totals.modified += area.totals.modified
            totals.deleted += area.totals.deleted
            totals.bytes += area.totals.bytes
        }
        let sorted = areas.values.sorted {
            ($0.totals.count, $0.totals.bytes, $1.path) > ($1.totals.count, $1.totals.bytes, $0.path)
        }
        return RunChanges(files: Array(sorted.prefix(RunReport.maxAreas)), fileTotals: totals,
                          preferences: preferencesReturned
                              ? Self.diff(preferences, Self.preferences(in: paths.prefs, prefixes: config.preferencePrefixes)) : nil)
    }

    // MARK: 文件

    /// 文件夹里所有不是文件夹的项目（文件、符号链接），相对路径 → 信息。不跟随符号链接
    /// （共享时主目录里的「下载」是指向你真实「下载」的链接，不进去），不进入挂载在里面的其他卷。
    /// 用 fts 直接读 stat：比 FileManager 的枚举（每个文件建一个属性字典）快好几倍
    static func entries(under root: URL) -> [String: Entry] {
        var result: [String: Entry] = [:]
        let rootPath = root.path
        guard let path = strdup(rootPath) else { return result }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return result }
        defer { fts_close(fts) }
        let prefix = rootPath.utf8.count + 1
        while let item = fts_read(fts) {
            switch Int32(item.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard item.pointee.fts_level > 0, let stat = item.pointee.fts_statp?.pointee else { continue }
                let full = String(cString: item.pointee.fts_path)
                let relative = String(decoding: full.utf8.dropFirst(prefix), as: UTF8.self)
                result[relative] = Entry(size: Int64(stat.st_size),
                                         modified: TimeInterval(stat.st_mtimespec.tv_sec) + TimeInterval(stat.st_mtimespec.tv_nsec) / 1e9,
                                         inode: UInt64(stat.st_ino))
            default:
                continue
            }
        }
        return result
    }

    /// 对比一处的前后，把改动按位置汇总进 areas
    private static func collect(before: [String: Entry], after: [String: Entry], location: FileArea.Location,
                                into areas: inout [String: FileArea]) {
        func add(_ relative: String, _ change: WritableKeyPath<FileTotals, Int>, size: Int64) {
            let key = areaKey(relative, location: location)
            var area = areas[key.path] ?? FileArea(location: location, path: key.path)
            area.totals[keyPath: change] += 1
            area.totals.bytes += size
            if change != \.deleted, area.examples.count < 3, let inside = key.inside { area.examples.append(inside) }
            areas[key.path] = area
        }
        // 按路径排序：例子取得稳定，每次对比同样的改动得到同样的报告
        for relative in after.keys.sorted() {
            guard let now = after[relative] else { continue }
            if let old = before[relative] {
                if old != now { add(relative, \.modified, size: now.size) }
            } else {
                add(relative, \.created, size: now.size)
            }
        }
        for relative in before.keys.sorted() where after[relative] == nil { add(relative, \.deleted, size: 0) }
    }

    /// 改动归到哪一处：主目录的 Library 下按“Library/类别/应用”（钥匙串只到 Library/Keychains），
    /// 其余按前两级（Documents/某个文件夹、.config/某个工具）；App 包按包里的前三级；「下载」按顶层项目。
    /// inside 是文件在这一处里面的相对路径；改动的就是这一处本身（一个文件）时为 nil
    static func areaKey(_ relative: String, location: FileArea.Location) -> (path: String, inside: String?) {
        let parts = relative.split(separator: "/").map(String.init)
        let depth = switch location {
        case .home: parts.first == "Library" ? (parts.dropFirst().first == "Keychains" ? 2 : 3) : 2
        case .app: 4 // X.app/Contents/Frameworks/Y.framework
        case .downloads: 1
        }
        let head = parts.prefix(depth).joined(separator: "/")
        let inside = parts.count > depth ? parts.dropFirst(depth).joined(separator: "/") : nil
        let path = switch location {
        case .home: "~/" + head
        case .app: head
        case .downloads: "~/Downloads/" + head
        }
        return (path, inside)
    }

    // MARK: 偏好设置

    /// 盒子保存的、属于这组前缀的域（Prefs 里的 .plist；.lease.json、.native 这些 MacBox 自己的不算）
    static func preferences(in folder: URL, prefixes: [String]) -> [String: [String: Data]] {
        var result: [String: [String: Data]] = [:]
        for url in FileOps.contents(of: folder) where url.pathExtension == "plist" {
            let domain = url.deletingPathExtension().lastPathComponent
            guard !domain.hasPrefix("."), PreferenceLease.domain(domain, isCoveredBy: prefixes),
                  let data = FileOps.regularFileContents(url),
                  let content = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            result[domain] = content.mapValues { value in
                (try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .xml, options: 0)) ?? Data()
            }
        }
        return result
    }

    static func diff(_ before: [String: [String: Data]], _ after: [String: [String: Data]]) -> [PreferenceChange] {
        Set(before.keys).union(after.keys).sorted().compactMap { domain in
            let old = before[domain] ?? [:], new = after[domain] ?? [:]
            let added = new.keys.filter { old[$0] == nil }.sorted()
            let removed = old.keys.filter { new[$0] == nil }.sorted()
            let changed = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
            guard !(added.isEmpty && removed.isEmpty && changed.isEmpty) else { return nil }
            let limit = 200
            return PreferenceChange(domain: domain, isNew: before[domain] == nil, added: Array(added.prefix(limit)),
                                    changed: Array(changed.prefix(limit)), removed: Array(removed.prefix(limit)))
        }
    }
}

// MARK: - 「下载」里的写入

/// 共享「下载」时应用在里面写了什么。MacBox 不去读你的「下载」（要你在系统设置里授权，也分不出哪些是你自己放的），
/// 由沙盒在应用每次写入时在系统日志里记一笔（见 SandboxProfile），这里按记下的操作推断：
/// 新建过的算新建；最后一下是删除的算删除，但新建又删掉的（下载到一半的临时文件、改名前的旧名字）不算；其余算修改。
/// 看不到大小（要读文件），也会因为系统日志限流漏记
final class DownloadWrites {
    /// 「下载」的真实路径（带结尾的 /）
    private let prefix = FileOps.realPath(AppPaths.realHome) + "/Downloads/"
    /// 相对「下载」的路径 → 先后的操作
    private var operations: [String: [String]] = [:]
    private var order: [String] = []

    /// 记下一条写入；不在「下载」里的不管
    func note(_ path: String, operation: String) {
        guard path.hasPrefix(prefix) else { return }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty else { return }
        if operations[relative] == nil { order.append(relative) }
        operations[relative, default: []].append(operation)
    }

    /// 按顶层项目汇总
    var areas: [FileArea] {
        var areas: [String: FileArea] = [:]
        for relative in order {
            let operations = operations[relative] ?? []
            let created = operations.contains { $0.hasPrefix("file-write-create") }
            let removed = operations.last?.hasPrefix("file-write-unlink") == true
            let change: WritableKeyPath<FileTotals, Int>
            switch (created, removed) {
            case (true, true): continue // 临时的
            case (false, true): change = \.deleted
            case (true, false): change = \.created
            case (false, false): change = \.modified
            }
            let key = RunSnapshot.areaKey(relative, location: .downloads)
            var area = areas[key.path] ?? FileArea(location: .downloads, path: key.path)
            area.totals[keyPath: change] += 1
            if change != \.deleted, area.examples.count < 3, let inside = key.inside { area.examples.append(inside) }
            areas[key.path] = area
        }
        return Array(areas.values)
    }
}

// MARK: - 存取

extension RunReport {
    /// 存进盒子的 Reports 文件夹，只留最近的 kept 份。文件名以开始时间开头，按名字排序就是按时间排序
    @concurrent
    static func save(_ report: RunReport, in paths: BoxPaths) async throws {
        try AppPaths.ensure(paths.reports)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let name = String(format: "%010d", Int(report.startedAt.timeIntervalSince1970)) + "-\(report.id.uuidString.prefix(8)).json"
        try encoder.encode(report).write(to: paths.reports.appending(path: name), options: .atomic)
        let files = FileOps.contents(of: paths.reports).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(kept) { try? FileOps.removeTree(old) }
    }

    /// 盒子里存着的报告，最近的在前。读不出来的跳过
    @concurrent
    static func load(from paths: BoxPaths) async -> [RunReport] {
        FileOps.contents(of: paths.reports).filter { $0.pathExtension == "json" }
            .compactMap { FileOps.regularFileContents($0).flatMap { try? JSONDecoder().decode(RunReport.self, from: $0) } }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - 导出

extension RunReport {
    static let projectURL = "https://github.com/PykeDLing/macbox"

    /// “18 分钟”“1 小时 5 分钟”“不到 1 分钟”
    var durationText: String {
        let minutes = Int(duration / 60)
        if minutes < 1 { return L("不到 1 分钟", "less than a minute") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .full
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: Localization.shared.isEnglish ? "en" : "zh-Hans")
        formatter.calendar = calendar
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)"
    }

    var timeText: String {
        let start = startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let endedAt else { return L("\(start) 开始，仍在运行", "Started \(start), still running") }
        let end = endedAt.formatted(date: .omitted, time: .shortened)
        return L("\(start) – \(end)（\(durationText)）", "\(start) – \(end) (\(durationText))")
    }

    /// 一行概要：写入 120 个文件 · 改了 34 项设置 · 连接 12 个服务器 · 启动 5 个程序 · 拦下 3 次
    var summaryLine: String {
        var parts: [String] = []
        if let totals = fileTotals { parts.append(L("写入 \(totals.count) 个文件", "\(totals.count) files written")) }
        if let keys = preferenceKeyCount { parts.append(L("改了 \(keys) 项设置", "\(keys) settings changed")) }
        parts.append(networkBlocked ? L("已断网", "offline")
                                    : L("连接 \(servers.count) 个服务器", "\(servers.count) servers contacted"))
        parts.append(L("启动 \(programs.count) 个程序", "\(programs.count) programs launched"))
        parts.append(L("拦下 \(blockCount) 次", "\(blockCount) attempts blocked"))
        return parts.joined(separator: " · ")
    }

    /// 完整的 Markdown 文字，用于拷贝、存储为文件
    func markdown() -> String {
        var lines: [String] = []
        lines.append(L("# 「\(appName)」运行报告", "# Run report: \(appName)"))
        lines.append("")
        lines.append(L("- 时间：\(timeText)", "- Time: \(timeText)"))
        lines.append(L("- 应用：\(appName)\(version.map { " \($0)" } ?? "")（\(bundleIdentifier)）",
                       "- App: \(appName)\(version.map { " \($0)" } ?? "") (\(bundleIdentifier))"))
        lines.append(L("- 网络：\(networkBlocked ? "已断开" : "允许")；「下载」文件夹：\(sharesDownloads ? "共享" : "不共享")",
                       "- Network: \(networkBlocked ? "blocked" : "allowed"); Downloads folder: \(sharesDownloads ? "shared" : "not shared")"))
        lines.append(L("- 由 MacBox 隔离运行并记录：\(Self.projectURL)", "- Run in isolation and recorded by MacBox: \(Self.projectURL)"))
        lines.append("")
        lines.append(L("**概要**：", "**Summary**: ") + summaryLine)

        lines.append("")
        lines.append(L("## 写入的文件", "## Files written"))
        lines.append("")
        if let files, let totals = fileTotals {
            if files.isEmpty {
                lines.append(L("没有写入文件。", "No files were written."))
            } else {
                lines.append(L("新建 \(totals.created)、修改 \(totals.modified)、删除 \(totals.deleted)，共 \(FileOps.formatBytes(totals.bytes))。路径是应用眼里的位置，实际都在 MacBox 的盒子里（「下载」除外）。",
                               "\(totals.created) created, \(totals.modified) modified, \(totals.deleted) deleted, \(FileOps.formatBytes(totals.bytes)) in total. Paths are where the app thinks it wrote; everything actually went into the MacBox box (except Downloads)."))
                lines.append("")
                lines.append(L("| 位置 | 新建 | 修改 | 删除 | 大小 |", "| Location | Created | Modified | Deleted | Size |"))
                lines.append("| --- | ---: | ---: | ---: | ---: |")
                for area in files {
                    lines.append("| \(cell(area.path)) | \(area.totals.created) | \(area.totals.modified) | \(area.totals.deleted) | \(FileOps.formatBytes(area.totals.bytes)) |")
                }
                if files.reduce(0, { $0 + $1.totals.count }) < totals.count {
                    lines.append("")
                    lines.append(L("（只列出改动最多的 \(files.count) 处）", "(Only the \(files.count) busiest locations are listed)"))
                }
            }
        } else {
            lines.append(isRunning ? L("应用退出后统计。", "Counted after the app quits.") : L("没能统计。", "Couldn’t be counted."))
        }

        lines.append("")
        lines.append(L("## 修改的设置", "## Settings changed"))
        lines.append("")
        if let preferences {
            if preferences.isEmpty { lines.append(L("没有改动偏好设置。", "No preferences were changed.")) }
            for change in preferences {
                lines.append("- `\(change.domain)`" + (change.isNew ? L("（新建）", " (new)") : ""))
                if !change.added.isEmpty { lines.append(L("  - 新增：", "  - Added: ") + keyList(change.added)) }
                if !change.changed.isEmpty { lines.append(L("  - 修改：", "  - Changed: ") + keyList(change.changed)) }
                if !change.removed.isEmpty { lines.append(L("  - 删除：", "  - Removed: ") + keyList(change.removed)) }
            }
        } else {
            lines.append(isRunning ? L("应用退出后统计。", "Counted after the app quits.")
                                   : L("偏好设置没能收回，这次没有统计。", "Preferences couldn’t be returned, so they weren’t counted."))
        }

        lines.append("")
        lines.append(L("## 连接的服务器", "## Servers contacted"))
        lines.append("")
        if networkBlocked {
            lines.append(L("这次运行不允许联网。", "Network access was blocked for this run."))
        } else if servers.isEmpty {
            lines.append(L("没有看到网络连接。", "No network connections were seen."))
        } else {
            lines.append(L("| 服务器 | 地址 | 协议 | 首次连接 |", "| Server | Address | Protocol | First seen |"))
            lines.append("| --- | --- | --- | --- |")
            for server in servers {
                lines.append("| \(cell(server.title)) | \(server.endpoint) | \(server.transport.uppercased()) | \(server.firstSeen.formatted(date: .omitted, time: .standard)) |")
            }
        }

        lines.append("")
        lines.append(L("## 启动的程序", "## Programs launched"))
        lines.append("")
        if programs.isEmpty {
            lines.append(L("没有看到启动程序。", "No program launches were seen."))
        } else {
            lines.append(L("| 程序 | 次数 | 说明 |", "| Program | Times | Note |"))
            lines.append("| --- | ---: | --- |")
            for program in programs { lines.append("| \(cell(program.path)) | \(program.count) | \(cell(program.note ?? "")) |") }
        }

        lines.append("")
        lines.append(L("## 被拦下的行为", "## Blocked attempts"))
        lines.append("")
        if blocks.isEmpty {
            lines.append(L("没有记录到被拦下的行为。", "No blocked attempts were recorded."))
        } else {
            lines.append(L("| 行为 | 对象 | 次数 |", "| Attempt | Target | Times |"))
            lines.append("| --- | --- | ---: |")
            for block in blocks { lines.append("| \(block.kind.title) | \(cell(block.targetText)) | \(block.count) |") }
        }

        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(Self.caveats)
        return lines.joined(separator: "\n") + "\n"
    }

    /// 报告记不全的地方，报告页和导出的文字都附上
    static var caveats: String {
        L("说明：连接是定时看一眼得到的，很短的连接可能没看到；服务器名字来自反向解析，常常是云服务商的机器名；设置了代理时，经由代理的连接只显示为连到代理。启动的程序、被拦下的行为、在共享的「下载」里写的文件来自系统日志，系统繁忙时会漏记，「下载」里的文件也没有大小。系统共用的临时文件夹不在统计之内。",
          "Notes: connections are sampled periodically, so very short ones may be missed; server names come from reverse DNS and are often cloud providers’ machine names; with a proxy, connections through it only show up as connections to the proxy. Program launches, blocked attempts and files written to the shared Downloads folder come from the system log and can be missed when the system is busy; Downloads files have no sizes. Shared system temporary folders aren’t counted.")
    }

    private func keyList(_ keys: [String]) -> String {
        keys.map { "`\($0)`" }.joined(separator: L("、", ", "))
    }

    /// 表格单元格里的竖线、换行会破坏表格
    private func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

}
