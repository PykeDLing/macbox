import Foundation

/// 盒子外、应用可以写入的文件夹（BoxConfig.writableFolders）：你在 MacBox 里选的。规则见 SandboxProfile，
/// 写了什么由系统日志记下、算进运行报告（见 SharedWrites）。
///
/// 只在选的时候解析一次真实路径（FileOps.realPath），之后原样使用、不碰文件系统：
/// - 应用把选定的文件夹删掉、换成指向别处的链接（它在放行的范围里，做得到）时，沙盒按解析后的真实路径判断，
///   写进链接的内容落在别处、被挡住。每次启动重新解析的话，MacBox 就会顺着链接把别处放行；
/// - 文件夹被删掉、外接硬盘没插上时照常生成规则，应用照常打开；
/// - MacBox 不去读这些文件夹：「文稿」「桌面」、外接硬盘要你授权，读了会弹窗问 MacBox
nonisolated enum WritableFolders {
    /// 不能选的原因
    enum Rejection: Error, Equatable, Sendable {
        /// 整块磁盘：/、/Volumes 和下面的每个卷、其他挂载点
        case disk
        /// 主目录本身和它的上级
        case home
        /// ~/Library：各个 App 的数据和设置（盒子也在里面）
        case library
        /// ~/Applications：聚焦里的启动器在那里，应用改了它们就能在盒子外运行
        case applications
        /// ~/Downloads 本身：有「共享「下载」文件夹」
        case downloads
        /// MacBox 的数据目录，它的上级和下级
        case macBoxData
        /// 隐藏文件夹（~/.config、~/.ssh……）：写进去的配置会被你自己的终端、工具执行
        case hidden
        /// 系统目录
        case system

        var message: String {
            switch self {
            case .disk: L("不能选整块磁盘，请在里面选一个文件夹。", "You can’t choose a whole disk. Choose a folder on it instead.")
            case .home: L("范围太大：不能选你的主目录或它的上级，请选里面的一个文件夹。",
                          "That’s too broad: you can’t choose your home folder or a folder above it. Choose a folder inside it.")
            case .library: L("「资源库」里是各个 App 的数据和设置，不能选。",
                             "The Library folder holds every app’s data and settings, so it can’t be chosen.")
            case .applications: L("这里有聚焦里的启动器，应用改了它们就能在盒子外运行，不能选。",
                                  "This holds the Spotlight launchers. An app that changed them could run outside the box, so it can’t be chosen.")
            case .downloads: L("「下载」本身请用「共享「下载」文件夹」；里面的文件夹可以选。",
                               "For Downloads itself, use “Share Downloads Folder”. Folders inside it can be chosen.")
            case .macBoxData: L("这是 MacBox 存放盒子的地方，不能选。应用本来就能写它自己盒子里的文件夹。",
                                "This is where MacBox keeps its boxes, so it can’t be chosen. Apps can already write to the folders in their own box.")
            case .hidden: L("隐藏文件夹里多是配置和凭证，写进去的配置会被你自己的终端和工具执行，不能选。",
                            "Hidden folders mostly hold settings and credentials, and settings written there would be run by your own terminal and tools, so they can’t be chosen.")
            case .system: L("这里是系统和你安装的 App，不能选。",
                            "This holds the system and the apps you’ve installed, so it can’t be chosen.")
            }
        }
    }

    /// 系统目录（真实路径）。/etc、/var、/tmp 是指向 /private 的链接，解析过的路径不会是它们，没解析的（日志、手工改过的）也挡住
    private static let systemFolders = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/etc", "/var",
                                        "/tmp", "/opt", "/cores", "/dev", "/Network"]

    /// 这个真实路径能不能选，不能选时给出原因。不碰文件系统：生成规则时（文件夹可能不在）、拦截记录给出的路径也用它。
    /// volumeRoot：选的时候读出它是一个卷的挂载点（挂在 /Volumes 之外的也算）
    static func check(_ path: String, home: String = realHome, dataRoot: String = realDataRoot,
                      volumeRoot: Bool = false) -> Rejection? {
        func within(_ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        func contains(_ inner: String) -> Bool { inner.hasPrefix(path + "/") }
        guard path.hasPrefix("/") else { return .system }
        if path == "/" || volumeRoot || path == "/Volumes" || path.wholeMatch(of: /\/Volumes\/[^\/]+/) != nil { return .disk }
        if path == home || contains(home) { return .home }
        if within(home + "/Library") { return .library } // 数据目录平时就在这里面，说「资源库」更清楚
        if within(home + "/Applications") { return .applications }
        if path == home + "/Downloads" { return .downloads }
        if within(dataRoot) || contains(dataRoot) { return .macBoxData }
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return .hidden }
        if systemFolders.contains(where: within) { return .system }
        return nil
    }

    /// 选择框里选中的文件夹：解析成真实路径再检查。选中的那一刻 MacBox 能读它，读卷信息不会弹窗
    static func resolve(_ url: URL) -> Result<String, Rejection> {
        let path = FileOps.realPath(url)
        let volumeRoot = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
        if let rejection = check(path, volumeRoot: volumeRoot) { return .failure(rejection) }
        return .success(path)
    }

    /// 生成规则、写报告时真正放行的：存下的路径再检查一遍（不碰文件系统），不合格的不放行。
    /// box.json 应用改不了，这只防手工改过的、以后的版本收紧了的
    static func granted(_ config: BoxConfig) -> [String] {
        let home = realHome, dataRoot = realDataRoot
        return config.writableFolderPaths.filter { check($0, home: home, dataRoot: dataRoot) == nil }
    }

    /// 被挡住的一次写入（拦截记录的对象：真实路径，或者报告里主目录写成 ~ 的）→ 可以允许写入的文件夹：被挡的文件所在的文件夹。
    /// 不是路径的、所在的文件夹不能选的为 nil。路径来自系统日志，内核记的已经是真实路径，不再解析
    /// （应用可能故意去写一个大的文件夹来引你点，所以照样检查，界面上也要确认）
    static func folder(forBlockedWrite target: String, home: String = realHome, dataRoot: String = realDataRoot) -> String? {
        let path = target.hasPrefix("~/") ? home + target.dropFirst(1) : target
        guard path.hasPrefix("/") else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return check(folder, home: home, dataRoot: dataRoot) == nil ? folder : nil
    }

    /// 显示的路径：主目录写成 ~（导出、分享的报告里不带你的用户名）
    static func displayPath(_ path: String, home: String = realHome) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// 在外接硬盘、网络磁盘上时，所在的卷（/Volumes/名字）
    static func volume(of path: String) -> String? {
        path.firstMatch(of: /^\/Volumes\/[^\/]+/).map { String($0.output) }
    }

    /// 已经接上的卷（挂载点）。读的是系统的挂载表，不碰磁盘本身，不会弹窗
    static func mountedVolumes() -> Set<String> {
        Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [], options: []) ?? []).map(\.path))
    }

    /// 应用第一次写入时 macOS 会问它要不要授权的位置。问的是盒子里的应用本身（它是自己的负责进程，见 ChildProcess 的
    /// disclaimResponsibility），不是 MacBox
    enum Protected: CaseIterable, Sendable {
        case drive, documents, desktop, downloads

        var name: String {
            switch self {
            case .drive: L("外接硬盘、网络磁盘", "external or network drives")
            case .documents: L("「文稿」", "Documents")
            case .desktop: L("「桌面」", "Desktop")
            case .downloads: L("「下载」", "Downloads")
            }
        }
    }

    static func protection(of path: String, home: String = realHome) -> Protected? {
        func within(_ base: String) -> Bool { path == base || path.hasPrefix(base + "/") }
        if volume(of: path) != nil { return .drive }
        if within(home + "/Documents") { return .documents }
        if within(home + "/Desktop") { return .desktop }
        if within(home + "/Downloads") { return .downloads }
        return nil
    }

    static var realHome: String { FileOps.realPath(AppPaths.realHome) }
    static var realDataRoot: String { FileOps.realPath(AppPaths.root) }
}
