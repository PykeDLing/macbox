import Foundation

/// hdiutil 封装
nonisolated enum DiskImage {
    struct Mount: Sendable {
        let device: String
        let mountPoint: URL
    }

    struct Attached: Sendable {
        let imagePath: String
        let devices: [String]
        let mountPoints: [String]
    }

    /// 只读、不在访达中显示地挂载
    static func attach(_ image: URL) async throws -> Mount {
        let result = try await attachRetrying(image)
        guard let range = result.output.range(of: "<?xml"),
              let plist = try PropertyListSerialization.propertyList(
                  from: Data(result.output[range.lowerBound...].utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw MacBoxError(L("无法读取磁盘映像信息", "Couldn’t read the disk image information"))
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, let device = entity["dev-entry"] as? String {
                return Mount(device: device, mountPoint: URL(fileURLWithPath: mountPoint, isDirectory: true))
            }
        }
        throw MacBoxError(L("磁盘映像里没有可读取的卷", "The disk image has no readable volume"))
    }

    /// 映像服务正忙（例如同时有其他映像在挂载、卸载）时 hdiutil 会报“资源暂时不可用”，稍等重试
    private static func attachRetrying(_ image: URL, attempts: Int = 4) async throws -> Shell.Result {
        for attempt in 1... {
            // 带许可协议的旧式 dmg 会在 stdin 等待确认
            let result = try await Shell.execute("/usr/bin/hdiutil",
                                                 ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-plist", image.path],
                                                 input: "Y\n")
            if result.status == 0 { return result }
            let busy = result.error.contains("暂时不可用") || result.error.localizedCaseInsensitiveContains("temporarily unavailable")
            guard busy, attempt < attempts else {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                throw MacBoxError(L("hdiutil 失败：\(detail)", "hdiutil failed: \(detail)"))
            }
            try await Task.sleep(for: .seconds(attempt))
        }
        fatalError()
    }

    static func detach(_ device: String) async {
        if (try? await Shell.run("/usr/bin/hdiutil", ["detach", device])) == nil {
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", "-force", device])
        }
    }

    static func attached() async -> [Attached] {
        guard let result = try? await Shell.run("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: result.outputData, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            return Attached(imagePath: path,
                            devices: entities.compactMap { $0["dev-entry"] as? String },
                            mountPoints: entities.compactMap { $0["mount-point"] as? String })
        }
    }

    /// 由某目录下的映像文件挂载出来的卷（例如盒子里的安装器自己下载并挂载的 dmg）
    static func attached(fromImagesUnder prefix: String) async -> [Attached] {
        await attached().filter { FileOps.realPath(URL(fileURLWithPath: $0.imagePath)).hasPrefix(prefix) }
    }
}
