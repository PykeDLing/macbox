import CryptoKit
import Foundation
import Virtualization

/// config.json 的内容。字段只增不改；新增字段必须是可选类型，旧文件才能照常读取
nonisolated struct VirtualMacConfig: Codable, Hashable, Sendable {
    var cpuCount = min(4, ProcessInfo.processInfo.processorCount)
    var memoryGB = min(8, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2)
    var diskGB = 64
    var networkEnabled = true
    var audioEnabled = true
    var macAddress = VZMACAddress.randomLocallyAdministered().string
    var osVersion: String?
    var installed = false
    var createdAt = Date()
    /// 设置时生成、开机时交给虚拟机的账户（见 GuestAccount）。旧版本设置的、宿主或客体低于 macOS 27 的没有
    var guestAccount: GuestAccount?

    /// 决定虚拟硬件的字段。睡眠状态只能用保存时同样的硬件唤醒（否则 VZErrorRestore），所以睡眠中不许改
    struct Hardware: Equatable, Sendable {
        var cpuCount: Int
        var memoryGB: Int
        var diskGB: Int
        var networkEnabled: Bool
        var audioEnabled: Bool
        var macAddress: String
    }

    /// 计算属性，不进 config.json
    var hardware: Hardware {
        get { Hardware(cpuCount: cpuCount, memoryGB: memoryGB, diskGB: diskGB, networkEnabled: networkEnabled,
                       audioEnabled: audioEnabled, macAddress: macAddress) }
        set {
            cpuCount = newValue.cpuCount
            memoryGB = newValue.memoryGB
            diskGB = newValue.diskGB
            networkEnabled = newValue.networkEnabled
            audioEnabled = newValue.audioEnabled
            macAddress = newValue.macAddress
        }
    }
}

/// 虚拟 Mac 里的账户。macOS 27 起，虚拟机开机时可以带上账户信息（VZMacGuestProvisioningOptions）：
/// 装好后第一次开机时系统据此建好账户、自动登录，不出现设置向导；之后的开机忽略它，改不了已经建好的账户。
/// 所以每次正常开机都带上：第一次开机被打断（强制关机、崩溃），下次开机照样能建好。
/// 开机自动登录用不着密码，在虚拟 Mac 里安装软件、改系统设置时会问，所以存在 config.json 里，在「虚拟 Mac」页显示
nonisolated struct GuestAccount: Codable, Hashable, Sendable {
    var fullName: String
    var username: String
    var password: String

    /// 全名用你在本机的全名。用户名固定，不跟着本机的：据测试版的反馈，和本机的用户名相同时建不成账户
    static func generate(hostFullName: String = NSFullUserName(), hostUserName: String = NSUserName()) -> GuestAccount {
        let name = hostFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return GuestAccount(fullName: name.isEmpty ? "MacBox" : name,
                            username: hostUserName == "macbox" ? "macboxvm" : "macbox",
                            password: randomPassword())
    }

    /// 要在虚拟 Mac 里手打（主机的剪贴板过不去），所以只用小写字母和数字，三组四个，约 56 位熵。
    /// 去掉容易看错的（0 o 1 l i），以及法语、德语键盘上位置不同的字母（a q w z y m）：虚拟 Mac 的键盘布局不一定和你的一样
    static func randomPassword() -> String {
        let alphabet = Array("bcdefghjknprstuvx23456789")
        var generator = SystemRandomNumberGenerator()
        return (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement(using: &generator)! }) }
            .joined(separator: "-")
    }
}

/// 虚拟 Mac 在磁盘上的布局：
///
///     VirtualMac/
///       config.json
///       Disk.img             虚拟硬盘（稀疏文件）
///       AuxiliaryStorage     NVRAM 等启动数据
///       HardwareModel / MachineIdentifier
///       SaveState.vzvmsave   睡眠时保存的内存状态
///       RestorePoint/        还原点（APFS 克隆）
///       QuarantineKey        给「传出」里的隔离标记签名的密钥
///       传入/                 主机 → 虚拟 Mac（只读）
///       传出/                 虚拟 Mac → 主机
nonisolated struct VirtualMacBundle: Sendable {
    let url: URL

    static let shared = VirtualMacBundle(url: AppPaths.virtualMac)

    var configURL: URL { url.appending(path: "config.json") }
    var diskURL: URL { url.appending(path: "Disk.img") }
    var auxiliaryStorageURL: URL { url.appending(path: "AuxiliaryStorage") }
    var hardwareModelURL: URL { url.appending(path: "HardwareModel") }
    var machineIdentifierURL: URL { url.appending(path: "MachineIdentifier") }
    var saveStateURL: URL { url.appending(path: "SaveState.vzvmsave") }
    var restorePointURL: URL { url.appending(path: "RestorePoint", directoryHint: .isDirectory) }
    var incomingURL: URL { url.appending(path: VMConfigurationFactory.incomingShareName, directoryHint: .isDirectory) }
    var outgoingURL: URL { url.appending(path: VMConfigurationFactory.outgoingShareName, directoryHint: .isDirectory) }
    var quarantineKeyURL: URL { url.appending(path: "QuarantineKey") }

    var restorableFiles: [URL] { [diskURL, auxiliaryStorageURL, saveStateURL] }
    /// 设置过程中创建的虚拟硬件（config.json 和交换文件夹不算）
    var setupArtifacts: [URL] { [diskURL, auxiliaryStorageURL, hardwareModelURL, machineIdentifierURL, saveStateURL] }

    /// 只有虚拟硬盘、没有 config.json。旧版本设置时不先写 config.json，中途取消、失败或退出就会留下这种状态；
    /// 设置完成时一定会写 config.json，所以这种状态下几乎不可能有装好的虚拟 Mac
    var isMissingConfig: Bool {
        !FileManager.default.fileExists(atPath: configURL.path) && FileManager.default.fileExists(atPath: diskURL.path)
    }

    /// 读取配置；还没有设置过（没有 config.json 也没有虚拟硬盘）时返回 nil。
    /// 文件存在却读不出来时抛错，绝不退回默认值：否则重新设置会删掉现有的虚拟硬盘
    func loadConfig() throws -> VirtualMacConfig? {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            if FileManager.default.fileExists(atPath: diskURL.path) {
                throw MacBoxError(String(localized: "找不到配置文件 config.json，但虚拟硬盘还在"))
            }
            return nil
        }
        do {
            return try JSONDecoder().decode(VirtualMacConfig.self, from: Data(contentsOf: configURL))
        } catch is DecodingError {
            throw MacBoxError(String(localized: "配置文件 config.json 格式无法识别，可能来自更新版本的 MacBox 或已损坏"))
        }
    }

    func save(_ config: VirtualMacConfig) throws {
        try AppPaths.ensure(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// 设置失败或取消时清掉已经创建的虚拟硬件。设置只会从「未设置」开始，这些文件里没有值得保留的东西
    func removeSetupArtifacts() {
        for file in setupArtifacts { try? FileOps.removeIfExists(file) }
    }

    /// 给「传出」里的隔离标记签名的密钥（见 OutgoingQuarantine.isValidMark），第一次用到时生成。
    /// 放在包的根目录：虚拟 Mac 只能看到「传入」「传出」，读不到它，也就伪造不了签名
    func quarantineKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: quarantineKeyURL), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try AppPaths.ensure(url)
        try? FileManager.default.removeItem(at: quarantineKeyURL)
        let data = key.withUnsafeBytes { Data($0) }
        guard FileManager.default.createFile(atPath: quarantineKeyURL.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw MacBoxError(String(localized: "无法保存隔离标记的密钥"))
        }
        return key
    }

    func ensureExchangeFolders() throws {
        try AppPaths.ensure(incomingURL)
        try AppPaths.ensure(outgoingURL)
    }

    func createPlatformFiles(hardwareModel: VZMacHardwareModel) throws {
        try AppPaths.ensure(url)
        try hardwareModel.dataRepresentation.write(to: hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxiliaryStorageURL, hardwareModel: hardwareModel,
                                      options: [.allowOverwrite])
    }

    func createDisk(sizeGB: Int) throws {
        try FileOps.removeIfExists(diskURL)
        guard FileManager.default.createFile(atPath: diskURL.path, contents: nil) else {
            throw MacBoxError(String(localized: "无法创建虚拟硬盘文件"))
        }
        let handle = try FileHandle(forWritingTo: diskURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeGB) << 30) // 稀疏文件：只有写入的部分占空间
    }

    func loadHardwareModel() throws -> VZMacHardwareModel {
        guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: hardwareModelURL)) else {
            throw MacBoxError(String(localized: "硬件型号数据损坏"))
        }
        guard model.isSupported else { throw MacBoxError(String(localized: "这台 Mac 不支持虚拟 Mac 的硬件型号")) }
        return model
    }

    func loadMachineIdentifier() throws -> VZMacMachineIdentifier {
        guard let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIdentifierURL)) else {
            throw MacBoxError(String(localized: "机器标识数据损坏"))
        }
        return id
    }
}
