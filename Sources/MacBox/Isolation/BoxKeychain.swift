import Foundation

/// 每个盒子一个独立钥匙串。
///
/// App 在重定向后的主目录里找 `Library/Keychains/login.keychain-db` 作为默认钥匙串，
/// 这里放一个指向 `box.keychain-db` 的符号链接（名为 login 的钥匙串无法用密码解锁），
/// 这样 App 存的登录凭证、设备 ID 都留在盒子里，不会进你的「登录」钥匙串。
nonisolated enum BoxKeychain {
    private static let security = "/usr/bin/security"

    @concurrent
    static func prepare(_ box: BoxPaths) async throws {
        try AppPaths.ensure(box.keychains)
        if !FileManager.default.fileExists(atPath: box.boxKeychain.path) {
            try await create(box)
        }
        if !FileOps.isSymlink(box.loginKeychainLink) {
            try FileOps.removeIfExists(box.loginKeychainLink)
            try FileManager.default.createSymbolicLink(atPath: box.loginKeychainLink.path,
                                                       withDestinationPath: box.boxKeychain.lastPathComponent)
        }
        let password = try String(contentsOf: box.keychainPassword, encoding: .utf8)
        try await Shell.run(security, ["unlock-keychain", "-p", password, box.boxKeychain.path])
    }

    private static func create(_ box: BoxPaths) async throws {
        let password = UUID().uuidString + UUID().uuidString
        FileManager.default.createFile(atPath: box.keychainPassword.path, contents: Data(password.utf8),
                                       attributes: [.posixPermissions: 0o600])
        // create-keychain 会把新钥匙串加进你的搜索列表，创建后立即恢复原列表
        let searchList = try await currentSearchList()
        let restore = ["list-keychains", "-d", "user", "-s"] + searchList
        do {
            try await Shell.run(security, ["create-keychain", "-p", password, box.boxKeychain.path])
        } catch {
            _ = try? await Shell.run(security, restore)
            throw error
        }
        try await Shell.run(security, restore)
        try await Shell.run(security, ["set-keychain-settings", box.boxKeychain.path]) // 不自动锁定
    }

    private static func currentSearchList() async throws -> [String] {
        let output = try await Shell.run(security, ["list-keychains", "-d", "user"]).output
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }
}
