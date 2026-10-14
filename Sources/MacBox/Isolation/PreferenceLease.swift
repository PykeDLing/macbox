import CoreFoundation
import Foundation

/// 偏好设置（UserDefaults）由系统服务 cfprefsd 代写，沙盒拦不住，也无法重定向。
/// 做法是“借出再收回”：启动前把系统里这些域的内容**整体替换**为盒子保存的内容，
/// 退出后把系统里的内容收回盒子，再把本机原来的内容整体换回去。
///
/// 这是对你真实系统状态的改动，所以按事务处理：
/// - 改动前先写日志 `Prefs/.lease.json`，记下进行到哪一步、动了哪些域；
/// - 借出中途失败立即回滚；MacBox 崩溃后，下次启动按日志把系统恢复原样；
/// - 每一步都可以重做：收回中途崩溃，重做时不会把本机设置误当成盒子的设置收进去。
///
/// 所有读写都经由 CFPreferences 直接和 cfprefsd 交互，域一律用绝对路径（不带 .plist）。
/// 只写域名时，如果本机装着同一个 App 的苹果沙盒版本，会被解析到
/// ~/Library/Containers/<id>/…/Preferences 里那份——那是用户本机 App 的真实设置。
nonisolated struct PreferenceLease: Sendable {
    let box: BoxPaths
    let prefixes: [String]
    /// 系统偏好设置目录（测试时可以换成别处）
    var systemPrefs = AppPaths.realHome.appending(path: "Library/Preferences", directoryHint: .isDirectory)

    init(box: BoxPaths, prefixes: [String]) {
        self.box = box
        self.prefixes = prefixes
    }

    private struct Journal: Codable {
        enum Phase: String, Codable {
            /// 正在把盒子的设置放进系统（盒子里的文件仍是权威版本）
            case lending
            /// 已借出，App 可能正在修改系统里的设置
            case lent
            /// 已收回盒子，正在恢复本机原设置（系统里的内容不能再收回）
            case returning
        }

        var phase: Phase
        /// 借出前本机已有的域（内容备份在 Prefs/.native）
        var nativeDomains: [String]
        /// 放进系统的盒子域
        var lentDomains: [String]
        /// 借出时的前缀（旧版的日志没有）。收回时只认这个范围里的域：借出没收回期间前缀变宽了（安装器接手后加上真正的 App），
        /// 用新前缀收回会把本机从没借出、也没备份过的域当成盒子的收进去，再当成“本机原本没有”清空
        var prefixes: [String]?
    }

    private var journalURL: URL { box.leaseJournal }

    /// 是否有未完成的借出（上次运行异常结束）
    var isOutstanding: Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
            || FileManager.default.fileExists(atPath: box.nativePrefsBackup.path) // 旧版 MacBox 只留下备份目录
    }

    // MARK: - 借出 / 收回

    /// 借出：系统里这些域的内容变成盒子保存的内容。失败时已做的改动全部撤销
    @concurrent
    func checkIn() async throws {
        if isOutstanding { try await checkOut() }
        try AppPaths.ensure(box.prefs)

        let native = systemDomains()
        let lent = boxDomains()
        var journal = Journal(phase: .lending, nativeDomains: native, lentDomains: lent, prefixes: prefixes)
        do {
            // 先记日志再动任何东西；本机的域全部备份完之后才开始替换
            try write(journal)
            try FileOps.removeIfExists(box.nativePrefsBackup)
            try AppPaths.ensure(box.nativePrefsBackup)
            for domain in native {
                try step(L("无法备份这台 Mac 上「\(domain)」的设置", "Couldn’t back up this Mac’s settings for “\(domain)”")) {
                    try savePlist(read(domain), to: box.nativePrefsBackup.appending(path: "\(domain).plist"))
                }
            }
            // 本机有、盒子里没有的域也要清空：否则 App 会读到本机的登录状态、设备 ID
            for domain in Set(native).union(lent) {
                try await step(L("无法把盒子里「\(domain)」的设置放进系统", "Couldn’t put the box’s settings for “\(domain)” in place")) {
                    try await replace(domain, with: loadPlist(box.prefs.appending(path: "\(domain).plist")) ?? [:])
                }
            }
            journal.phase = .lent
            try write(journal)
        } catch {
            try? await checkOut()
            throw error
        }
    }

    /// 收回：系统里的内容存回盒子，再恢复本机原来的内容。可重复调用。
    ///
    /// 失败时日志和本机设置的备份原样留着（isOutstanding 仍为 true），下次调用从中断处继续；
    /// 抛出的错误写明卡在哪一步、哪个域、为什么，调用方可以直接拿去告诉用户——这时本机这个应用的设置
    /// 可能还是盒子里的内容，悄悄吞掉的话，之后的清除数据、还原会把唯一的备份一起删掉
    @concurrent
    func checkOut() async throws {
        guard var journal = readJournal() else {
            // 读不出日志、也没有 .native：没有要恢复的东西（.native 在替换任何域之前就建好，全部恢复之后才删除）。
            // 这时日志的位置上要是还有东西——盒子里的 App 把它换成了符号链接、FIFO、乱码——也删掉（链接只删链接本身）：
            // 留着的话 isOutstanding 一直为真，清除数据、还原、删除都会被它挡住，直到下次启动借出时覆盖它。
            // 按 lstat 判断有没有：什么都没有时（平常收回的情形）不多做任何事
            var info = stat()
            if lstat(journalURL.path, &info) == 0 {
                try step(L("无法删除读不出来的借出日志", "Couldn’t remove the unreadable lease journal")) {
                    try FileOps.removeTree(journalURL)
                }
            }
            return
        }
        // 只收借出时那组前缀里的（见 Journal.prefixes）。日志在盒子里，只能用来缩小范围，owns 照样按现在的前缀把关
        let lentScope = journal.prefixes ?? prefixes
        let domains = Set(systemDomains().filter { Self.domain($0, isCoveredBy: lentScope) })
            .union(journal.nativeDomains).union(journal.lentDomains)

        if journal.phase == .lent {
            for domain in domains {
                try step(L("无法把「\(domain)」的设置存回盒子", "Couldn’t save the settings for “\(domain)” back to the box")) {
                    let content = read(domain)
                    let file = box.prefs.appending(path: "\(domain).plist")
                    if content.isEmpty { try FileOps.removeIfExists(file) } else { try savePlist(content, to: file) }
                }
            }
        }
        if journal.phase != .returning {
            journal.phase = .returning
            try step(L("无法记录偏好设置的收回进度", "Couldn’t record the progress of returning preferences")) {
                try write(journal)
            }
        }
        for domain in domains {
            try await step(L("无法恢复这台 Mac 上「\(domain)」原来的设置", "Couldn’t restore this Mac’s original settings for “\(domain)”")) {
                if let original = loadPlist(box.nativePrefsBackup.appending(path: "\(domain).plist")) {
                    try await replace(domain, with: original)
                } else if !journal.nativeDomains.contains(domain) {
                    try await replace(domain, with: [:]) // 本机原本没有这个域
                }
                // 本机原有、却还没有备份的域：借出在备份阶段中断，它从未被改动过，保持原样
            }
        }
        try step(L("偏好设置已经收回，但无法删除借出日志", "Preferences were returned, but the lease journal couldn’t be removed")) {
            try FileOps.removeIfExists(box.nativePrefsBackup)
            try FileOps.removeIfExists(journalURL)
        }
    }

    /// 给出错的一步加上说明：「哪一步：原因」
    private func step<T>(_ what: String, _ work: () throws -> T) throws -> T {
        do { return try work() } catch { throw MacBoxError(L("\(what)：\(error.localizedDescription)", "\(what): \(error.localizedDescription)")) }
    }

    private func step<T>(_ what: String, _ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch { throw MacBoxError(L("\(what)：\(error.localizedDescription)", "\(what): \(error.localizedDescription)")) }
    }

    // MARK: - 域

    /// 域是否属于这组前缀（前缀本身，或以“前缀.”开头）
    static func domain(_ domain: String, isCoveredBy prefixes: [String]) -> Bool {
        prefixes.contains { domain == $0 || domain.hasPrefix($0 + ".") }
    }

    /// 能不能当作这个盒子的域来读写。
    ///
    /// 域名会直接拼进路径：系统偏好设置目录、Prefs、Prefs/.native。而日志 .lease.json 和 Prefs 都在盒子目录里，
    /// 盒子里的 App 改得到——不检查的话，它往日志里写一个 "../../Documents/x"，收回时不在沙盒里的 MacBox
    /// 就会替它删除、覆盖、读出盒子外的任意 .plist，或者借出、清空别的应用的偏好设置。
    /// 所以只认单个文件名（没有 /、不含 ..、不以 . 开头），并且属于这个盒子的前缀；其余一律当作不存在
    private func owns(_ domain: String) -> Bool {
        !domain.isEmpty && !domain.hasPrefix(".") && !domain.contains("/") && !domain.contains("..")
            && !domain.contains("\0") && Self.domain(domain, isCoveredBy: prefixes)
    }

    /// 两组前缀会不会借出同一个域。会的话两个盒子不能同时运行：
    /// 后借出的一方会把前一方借出的内容当成本机设置备份起来，收回时互相覆盖，最后连本机设置都换成了盒子的
    static func overlaps(_ a: [String], _ b: [String]) -> Bool {
        a.contains { domain($0, isCoveredBy: b) } || b.contains { domain($0, isCoveredBy: a) }
    }

    /// 系统里属于这个 App 的域（App、安装器和各种 helper）
    private func systemDomains() -> [String] { plistNames(in: systemPrefs).filter(owns) }

    /// 盒子保存的域。Prefs 里的文件 App 也放得进去，不属于这个盒子的不借出
    private func boxDomains() -> [String] { plistNames(in: box.prefs).filter(owns) }

    private func plistNames(in directory: URL) -> [String] {
        FileOps.contents(of: directory)
            .filter { $0.pathExtension == "plist" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    private func reference(_ domain: String) -> CFString { systemPrefs.appending(path: domain).path as CFString }

    /// 读取 cfprefsd 里的最新内容
    private func read(_ domain: String) -> [String: Any] {
        let ref = reference(domain)
        CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let keys = CFPreferencesCopyKeyList(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else { return [:] }
        return CFPreferencesCopyMultiple(keys as CFArray, ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any] ?? [:]
    }

    /// 整体替换（不是合并）：不在新内容里的键全部删除；内容为空时整个域从系统删除
    private func replace(_ domain: String, with content: [String: Any]) async throws {
        let ref = reference(domain)
        CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let existing = CFPreferencesCopyKeyList(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        let removed = existing.filter { content[$0] == nil }
        CFPreferencesSetMultiple(content as CFDictionary, removed as CFArray, ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(ref, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            // 调用方会加上是哪个域、哪一步
            throw MacBoxError(L("偏好设置服务（cfprefsd）没有接受修改", "The preferences service (cfprefsd) didn’t accept the change"))
        }
        if content.isEmpty {
            // 只删文件不够：cfprefsd 稍后会把缓存里的空域重新写成一个空 plist。让它自己删除整个域
            _ = try? await Shell.run("/usr/bin/defaults", ["delete", ref as String])
            try FileOps.removeIfExists(systemPrefs.appending(path: "\(domain).plist"))
        }
    }

    // MARK: - 文件

    /// 只读盒子里的文件（Prefs、Prefs/.native），App 改得到：是指向盒子外的符号链接时当作没有，
    /// 否则 MacBox 会把链接指向的任意 .plist 借给 App 读
    private func loadPlist(_ url: URL) -> [String: Any]? {
        guard let data = FileOps.regularFileContents(url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func savePlist(_ content: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0).write(to: url, options: .atomic)
    }

    private func write(_ journal: Journal) throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    /// 日志和备份目录都在盒子里，App 改得到：里面的域名逐个检查（见 owns），不属于这个盒子的当作没有
    private func readJournal() -> Journal? {
        if let data = FileOps.regularFileContents(journalURL), var journal = try? JSONDecoder().decode(Journal.self, from: data) {
            journal.nativeDomains = journal.nativeDomains.filter(owns)
            journal.lentDomains = journal.lentDomains.filter(owns)
            return journal
        }
        // 旧版 MacBox 崩溃后只留下备份目录：视为已借出
        guard FileManager.default.fileExists(atPath: box.nativePrefsBackup.path) else { return nil }
        return Journal(phase: .lent, nativeDomains: plistNames(in: box.nativePrefsBackup).filter(owns), lentDomains: boxDomains(),
                       prefixes: nil)
    }
}
