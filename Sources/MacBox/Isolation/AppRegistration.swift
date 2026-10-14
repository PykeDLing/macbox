import Foundation

/// 系统（LaunchServices）对盒子里 App 的登记。登记着的 App 声明的 URL scheme、文档类型都指向它，
/// 「打开方式」里也会列出它：MacBox 没在运行时点个链接、双击个文档，就会绕过 MacBox 打开它
/// （App 平时上锁，打开会失败，但不该留着这条路）
nonisolated enum AppRegistration {
    /// 撤销 App 包和包里嵌套的 App（登录项、辅助程序、包里附带的小工具……）的登记。
    /// 只用 -u 只撤销最外层，加 -R 才会扫描包里面。最外层已经没有登记时 lsregister 会报 -10814、退出码非 0，
    /// 但里面的照样撤销了，所以不看退出码
    static func unregister(_ app: URL) async {
        _ = try? await Shell.execute(Shell.lsregister, ["-u", "-R", app.path])
    }

    /// 撤销路径在 root 下的所有登记，包括文件夹已经不在的（换掉的 App.new、App.old，删掉的盒子）：
    /// 登记按路径记着，文件没了也照样留着，而路径不存在时 -R 扫描不了包里面，只能按 lsregister -dump 列出的路径逐个撤销。
    /// -dump 要两三秒、输出几十 MB，只在启动时在后台做一次
    @concurrent
    static func unregisterAll(under root: URL) async {
        guard let dump = try? await Shell.execute(Shell.lsregister, ["-dump"]) else { return }
        for path in registeredPaths(in: dump.output, under: root) {
            _ = try? await Shell.execute(Shell.lsregister, ["-u", path])
        }
    }

    /// 从 lsregister -dump 的输出里取出路径在 root 下的登记（“path:    /…/X.app (0x1a2b)”），去掉重复
    static func registeredPaths(in dump: String, under root: URL) -> [String] {
        // -dump 里是真实路径；root 可能经过符号链接（例如 /tmp），两种写法都认
        let prefixes = Set([root.standardizedFileURL.path, FileOps.realPath(root)]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var paths: [String] = []
        for line in dump.split(separator: "\n") where line.hasPrefix("path:") {
            var path = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            if let suffix = path.range(of: #" \(0x[0-9a-f]+\)$"#, options: .regularExpression) { path.removeSubrange(suffix) }
            if prefixes.contains(where: { path.hasPrefix($0) }), !paths.contains(path) { paths.append(path) }
        }
        return paths
    }
}
