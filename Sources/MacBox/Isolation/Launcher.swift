import Foundation

/// 在 ~/Applications/MacBox 里放一个和原 App 同名同图标的启动器，
/// 从聚焦、程序坞打开它时，由 MacBox 在隔离中启动真正的 App。
/// 所有改动经由这个 actor 串行执行：并发安装时“找空闲名字”会互相踩到，产生重复的启动器
actor Launcher {
    static let shared = Launcher()

    /// 启动器的写法，记在它的 Info.plist（MacBoxLauncherVersion，没有的是 1）。写法变了就加一，
    /// MacBox 启动时把旧的重写一遍（见 BoxStore.reload）：
    /// - 2：脚本不再用 `open -g`。-g 让 MacBox 留在后台，协作式激活下后台的 MacBox 让不出前台，
    ///   从聚焦打开的 App 窗口留在原来的 App 后面，已经在运行的也切不过去
    static let version = 2

    /// 启动器所属的盒子。直接读 Info.plist：Bundle(url:) 会缓存同一路径的旧内容
    nonisolated static func boxID(of launcher: URL) -> String? {
        info(of: launcher)?["MacBoxBoxID"] as? String
    }

    nonisolated static func version(of launcher: URL) -> Int {
        info(of: launcher)?["MacBoxLauncherVersion"] as? Int ?? 1
    }

    private nonisolated static func info(of launcher: URL) -> NSDictionary? {
        NSDictionary(contentsOf: launcher.appending(path: "Contents/Info.plist"))
    }

    private func all() -> [URL] {
        FileOps.contents(of: AppPaths.launchers).filter { $0.pathExtension == "app" && Self.boxID(of: $0) != nil }
    }

    /// 这个盒子是否已有启动器
    func hasLauncher(for id: UUID) -> Bool {
        all().contains { Self.boxID(of: $0) == id.uuidString }
    }

    /// 这个盒子的启动器要不要（重新）安装：还没有，或者是旧写法的
    func needsInstall(for id: UUID) -> Bool {
        let mine = all().filter { Self.boxID(of: $0) == id.uuidString }
        return mine.isEmpty || mine.contains { Self.version(of: $0) < Self.version }
    }

    /// 删除不属于任何现存盒子的启动器，以及旧版留下的、all() 看不到的启动器（见 removeHiddenAndNested）
    func removeOrphans(keeping ids: Set<UUID>) async {
        for launcher in all() where !ids.contains(where: { $0.uuidString == Self.boxID(of: launcher) }) {
            await delete(launcher)
        }
        await removeHiddenAndNested()
    }

    /// 旧版没有处理名称里的“/”和开头的“.”：启动器建在了子文件夹里（「夸克网盘/工作」→ 夸克网盘/工作.app），
    /// 或者成了隐藏文件。all() 只看顶层、不看隐藏文件，找不到它们，每次启动都再建一个新的，删除盒子时也删不掉。
    /// 按 MacBoxBoxID 认出这些启动器，不管主人在不在都删掉：主人还在的，同步时会在顶层用处理过的名字重建。
    /// 只扫启动器文件夹，代价很小，每次启动都扫一遍
    private func removeHiddenAndNested() async {
        let root = AppPaths.launchers.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: AppPaths.launchers, includingPropertiesForKeys: nil) else { return }
        var stale: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "app" else { continue }
            enumerator.skipDescendants() // 不进启动器包里面
            let parent = item.deletingLastPathComponent().standardizedFileURL.path
            let visible = parent == root && !item.lastPathComponent.hasPrefix(".")
            if !visible, Self.boxID(of: item) != nil { stale.append(item) }
        }
        for launcher in stale {
            await delete(launcher)
            // 删空了的子文件夹也删掉（rmdir 只删空文件夹）
            var folder = launcher.deletingLastPathComponent().standardizedFileURL
            while folder.path.hasPrefix(root + "/"), rmdir(folder.path) == 0 {
                folder = folder.deletingLastPathComponent().standardizedFileURL
            }
        }
    }

    /// 应用名称（可以在详情里随意改）转成能直接作为文件名的样子：
    /// - “/”在访达里显示的名字对应文件系统里的“:”，换过去显示出来仍是原名；否则会建出一层子文件夹
    /// - 去掉开头的“.”，否则成了隐藏文件。两种情况 all() 都找不到它，启动器会越积越多
    /// - 留出“ 99.app”的位置，不超过文件名长度上限（255 字节），不截断半个字
    nonisolated static func fileName(for name: String) -> String {
        var result = name.replacingOccurrences(of: "/", with: ":")
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)
        while result.utf8.count > 200 { result.removeLast() }
        return result.isEmpty ? "App" : result
    }

    /// 同名应用装了多份（比如两个网盘账号）时，启动器依次叫「夸克网盘」「夸克网盘 2」
    private func freeURL(for config: BoxConfig) -> URL {
        let base = Self.fileName(for: config.name)
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let candidate = AppPaths.launchers.appending(path: "\(name).app", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// 启动器的脚本：经由 URL 交给 MacBox。不加 -g：MacBox 要先到前台，才能把前台让给盒子里的 App（见 version）
    nonisolated static func script(for id: UUID) -> String {
        "#!/bin/sh\nexec /usr/bin/open \"macbox://open/\(id.uuidString)\"\n"
    }

    func install(paths: BoxPaths, config: BoxConfig) async throws {
        await remove(boxID: config.id)
        let launcher = freeURL(for: config)
        let contents = launcher.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        let resources = contents.appending(path: "Resources")
        try AppPaths.ensure(macOS)
        try AppPaths.ensure(resources)

        var info: [String: Any] = [
            "CFBundleIdentifier": "dev.pyke.MacBox.launcher.\(config.id.uuidString)",
            "CFBundleName": config.name,
            "CFBundleDisplayName": config.name,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": config.version ?? "1.0",
            "LSUIElement": true,
            "MacBoxBoxID": config.id.uuidString,
            "MacBoxLauncherVersion": Self.version,
        ]
        // 沿用原 App 的图标（.icns 或 Assets.car）
        let app = paths.app(config)
        let appResources = app.appending(path: "Contents/Resources")
        let appInfo = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        if var iconFile = appInfo["CFBundleIconFile"] as? String {
            if !iconFile.hasSuffix(".icns") { iconFile += ".icns" }
            try? FileOps.clone(appResources.appending(path: iconFile), to: resources.appending(path: "AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        if let iconName = appInfo["CFBundleIconName"] as? String {
            try? FileOps.clone(appResources.appending(path: "Assets.car"), to: resources.appending(path: "Assets.car"))
            info["CFBundleIconName"] = iconName
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))

        let script = macOS.appending(path: "launch")
        try Self.script(for: config.id).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try? await Shell.run(Shell.lsregister, ["-f", launcher.path])
    }

    /// 只删除属于这个盒子的启动器
    func remove(boxID id: UUID) async {
        for item in all() where Self.boxID(of: item) == id.uuidString {
            await delete(item)
        }
    }

    /// 先撤销登记再删：聚焦、「打开方式」里不留指向已删除启动器的记录
    private func delete(_ launcher: URL) async {
        _ = try? await Shell.run(Shell.lsregister, ["-u", launcher.path])
        try? FileOps.removeTree(launcher)
    }
}
