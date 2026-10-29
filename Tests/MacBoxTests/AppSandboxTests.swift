import Foundation
import Testing
@testable import MacBox

/// 自带苹果沙盒的判断：按值读签名里的权限；真用的本机隔离装不下（套上 sandbox-exec 一启动就会被系统结束），
/// 添加时建议改用虚拟 Mac、打开时不启动它；旧盒子记着的那一条启动时更正（见 BoxStore.recheckedAppSandbox）。
/// 只在临时目录里造 App 包、做 ad-hoc 签名，不运行它们
@Suite("苹果沙盒")
final class AppSandboxTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests-sandbox-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    func app(_ name: String, entitlements: [String: Any]?, signed: Bool = true) async throws -> URL {
        let url = root.appending(path: "\(UUID().uuidString)/\(name).app")
        try await SignedTestApp.make(at: url, identifier: "dev.macboxtest.sandbox.\(name.lowercased())",
                                     entitlements: entitlements, signed: signed)
        return url
    }

    @Test("按值判断：写着“是”的才算用苹果沙盒；写着“否”的、没有这一项的、没签名的都不算")
    func readsValue() async throws {
        let sandboxed = try await app("Yes", entitlements: ["com.apple.security.app-sandbox": true,
                                                            "com.apple.security.network.client": true])
        let declined = try await app("No", entitlements: ["com.apple.security.app-sandbox": false,
                                                          "com.apple.security.network.client": true])
        let other = try await app("Other", entitlements: ["com.apple.security.network.client": true])
        let plain = try await app("Plain", entitlements: nil)
        let unsigned = try await app("Unsigned", entitlements: nil, signed: false)

        #expect(AppInspector.entitlements(of: declined)["com.apple.security.app-sandbox"] as? Bool == false, "要读得出“否”")
        #expect(AppInspector.usesAppSandbox(sandboxed))
        #expect(!AppInspector.usesAppSandbox(declined))
        #expect(!AppInspector.usesAppSandbox(other))
        #expect(!AppInspector.usesAppSandbox(plain))
        #expect(AppInspector.entitlements(of: unsigned).isEmpty)
        #expect(!AppInspector.usesAppSandbox(unsigned))
    }

    @Test("上了锁（没有执行权限）的 App 也读得出：启动前、启动 MacBox 时 App 都是锁着的")
    func readsLockedApp() async throws {
        let sandboxed = try await app("Locked", entitlements: ["com.apple.security.app-sandbox": true])
        try AppLock.lock(sandboxed)
        #expect(AppLock.isLocked(sandboxed))
        #expect(AppInspector.usesAppSandbox(sandboxed))
    }

    @Test("添加时的检查：真用苹果沙盒的记一条“本机隔离装不下”，写着“否”的不记")
    func scan() async throws {
        let sandboxed = try await app("Yes", entitlements: ["com.apple.security.app-sandbox": true])
        let declined = try await app("No", entitlements: ["com.apple.security.app-sandbox": false])

        let issue = try #require(await AppInspector.scan(sandboxed).first { $0.code == .appSandbox })
        #expect(issue.severity == .needsVirtualMac)
        Localization.$testLanguage.withValue(.chinese) {
            #expect(issue.localizedDetail.contains("本机隔离装不下它"))
            #expect(!issue.localizedDetail.contains("数据存进盒子"))
        }
        Localization.$testLanguage.withValue(.english) {
            #expect(issue.localizedDetail.contains("Native Isolation can’t hold it"))
        }
        #expect(!(await AppInspector.scan(declined)).contains { $0.code == .appSandbox })
    }

    @Test("打开前按盒子里现在的 App 判断：真用苹果沙盒的不启动、说明原因，其余照常")
    func refusesToLaunch() async throws {
        let sandboxed = try await app("Yes", entitlements: ["com.apple.security.app-sandbox": true])
        let declined = try await app("No", entitlements: ["com.apple.security.app-sandbox": false])
        try Localization.$testLanguage.withValue(.chinese) {
            let error = #expect(throws: MacBoxError.self) { try IsolatedSession.refuseAppSandbox(sandboxed, name: "看番") }
            #expect(error?.localizedDescription.contains("「看番」自带苹果沙盒") == true)
            #expect(error?.localizedDescription.contains("虚拟 Mac") == true)
            try IsolatedSession.refuseAppSandbox(declined, name: "Docker")
        }
    }

    @Test("询问的说法：自带苹果沙盒的一定运行不了，不说“可能”；其他问题照旧说“可能”")
    func promptWording() {
        let sandboxed = CompatibilityPrompt(boxID: UUID(), appName: "看番", reasons: ["自带苹果沙盒：…"], cannotRunNatively: true)
        let other = CompatibilityPrompt(boxID: UUID(), appName: "加速器", reasons: ["系统服务：…"])
        Localization.$testLanguage.withValue(.chinese) {
            #expect(sandboxed.title == "「看番」无法在本机隔离中运行")
            #expect(!sandboxed.message.contains("可能") && !sandboxed.message.contains("完整功能"))
            #expect(other.title == "「加速器」在本机隔离中可能无法正常使用")
            #expect(other.message.contains("完整功能"))
        }
        Localization.$testLanguage.withValue(.english) {
            #expect(sandboxed.title == "“看番” can’t run in Native Isolation")
            #expect(sandboxed.message.hasSuffix("To run it in MacBox, use Virtual Mac."))
        }
    }

    @Test("旧盒子记着的“自带苹果沙盒”：不用的去掉，真用的原地换成现在的级别和说明，其他问题不动")
    func recheck() {
        var old = CompatibilityIssue(.appSandbox)
        old.severity = .info // 0.4.1 及以前当作参考信息
        old.detail = "在 MacBox 中它改由 MacBox 的沙盒约束，数据存进盒子；请经由 MacBox 打开它。"
        let issues = [CompatibilityIssue(.notarized), old, CompatibilityIssue(.loginItem)]

        #expect(BoxStore.recheckedAppSandbox(issues, usesAppSandbox: false)
            == [CompatibilityIssue(.notarized), CompatibilityIssue(.loginItem)])
        let upgraded = BoxStore.recheckedAppSandbox(issues, usesAppSandbox: true)
        #expect(upgraded == [CompatibilityIssue(.notarized), CompatibilityIssue(.appSandbox), CompatibilityIssue(.loginItem)])
        #expect(upgraded[1].severity == .needsVirtualMac)
        let unmarked = [CompatibilityIssue(.loginItem)]
        #expect(BoxStore.recheckedAppSandbox(unmarked, usesAppSandbox: false) == unmarked)
    }
}
