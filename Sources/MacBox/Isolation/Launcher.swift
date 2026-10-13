import Foundation

/// 在 ~/Applications/MacBox 里放一个和原 App 同名同图标的启动器，
/// 从启动台、聚焦、程序坞打开它时，由 MacBox 在隔离中启动真正的 App。
/// 所有改动经由这个 actor 串行执行：并发安装时“找空闲名字”会互相踩到，产生重复的启动器
actor Launcher {
    static let shared = Launcher()

    /// 启动器所属的盒子。直接读 Info.plist：Bundle(url:) 会缓存同一路径的旧内容
    nonisolated static func boxID(of launcher: URL) -> String? {
        NSDictionary(contentsOf: launcher.appending(path: "Contents/Info.plist"))?["MacBoxBoxID"] as? String
    }

    private func all() -> [URL] {
        FileOps.contents(of: AppPaths.launchers).filter { $0.pathExtension == "app" && Self.boxID(of: $0) != nil }
    }

    /// 这个盒子是否已有启动器
    func hasLauncher(for id: UUID) -> Bool {
        all().contains { Self.boxID(of: $0) == id.uuidString }
    }

    /// 删除不属于任何现存盒子的启动器
    func removeOrphans(keeping ids: Set<UUID>) {
        for launcher in all() where !ids.contains(where: { $0.uuidString == Self.boxID(of: launcher) }) {
            try? FileManager.default.removeItem(at: launcher)
        }
    }

    /// 同名应用装了多份（比如两个网盘账号）时，启动器依次叫「夸克网盘」「夸克网盘 2」
    private func freeURL(for config: BoxConfig) -> URL {
        var index = 1
        while true {
            let name = index == 1 ? config.name : "\(config.name) \(index)"
            let candidate = AppPaths.launchers.appending(path: "\(name).app", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    func install(paths: BoxPaths, config: BoxConfig) async throws {
        remove(boxID: config.id)
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
        try "#!/bin/sh\nexec /usr/bin/open -g \"macbox://open/\(config.id.uuidString)\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = try? await Shell.run(Shell.lsregister, ["-f", launcher.path])
    }

    /// 只删除属于这个盒子的启动器
    func remove(boxID id: UUID) {
        for item in all() where Self.boxID(of: item) == id.uuidString {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
