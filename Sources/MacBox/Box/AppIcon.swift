import AppKit
import UniformTypeIdentifiers

/// App 的图标，直接从包里的资源读
nonisolated enum AppIcon {
    /// 不用 NSWorkspace.icon(forFile:)：它会顺手把 App 登记进 LaunchServices。盒子里的 App 一登记，
    /// 它声明的 URL scheme、文档类型、“打开方式”就都指向它，MacBox 没在运行时，点个链接就能在隔离之外把它打开。
    /// 按 Info.plist 自己找（直接读文件，理由见 AppInspector.info）：CFBundleIconFile 指向的 .icns；
    /// 没有再取 CFBundleIconName 在 Assets.car 里的图标，资源目录只能经由 Bundle 读（不会登记）。
    /// 都没有时用通用的 App 图标。要读磁盘，盒子多时请在后台调用
    static func load(_ app: URL) -> NSImage {
        let info = AppInspector.infoDictionary(of: app) ?? [:]
        if let file = info["CFBundleIconFile"] as? String, !file.isEmpty, !file.contains("/") {
            let resources = app.appending(path: "Contents/Resources")
            // 写不写扩展名都有：“AppIcon”“AppIcon.icns”
            for candidate in [file, file + ".icns"] {
                let url = resources.appending(path: candidate)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                   let image = NSImage(contentsOf: url), image.isValid {
                    return image
                }
            }
        }
        // Bundle 按路径缓存：同一路径上的 App 换过（安装器被换成真正的 App）时，缓存里的还是旧的，
        // 标识符对不上就不用它的资源，免得拿安装器的图标当 App 的
        if let name = info["CFBundleIconName"] as? String, !name.isEmpty,
           let bundle = Bundle(url: app), bundle.bundleIdentifier == info["CFBundleIdentifier"] as? String,
           let image = bundle.image(forResource: name), image.isValid {
            return image
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
