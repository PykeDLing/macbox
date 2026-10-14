import Foundation
import Testing
@testable import MacBox

/// 盒子钥匙串与你的钥匙串搜索列表。`security` 换成一个假命令：它把“用户搜索列表”记在文件里，
/// create-keychain 和真的一样先把新钥匙串加进列表（记下解析过符号链接的真实路径，如 /private/var/…），
/// 再稍等一会儿才建好文件，好让两次创建交错。真实的搜索列表从头到尾只读不写，结束时核对没有变化
@Suite("盒子钥匙串")
struct BoxKeychainTests {
    let root: URL
    let fake: URL
    let state: URL
    let failMarker: URL
    /// 你的“登录”钥匙串和一个无关的钥匙串：这两项任何时候都不能被拿掉，顺序也不能变
    let original: [String]

    init() throws {
        // 路径里带空格：搜索列表的每一项必须作为单独的参数传给 security
        root = FileManager.default.temporaryDirectory.appending(path: "MacBoxTests Keychain-\(UUID().uuidString)")
        fake = root.appending(path: "bin/security")
        state = root.appending(path: "search-list")
        failMarker = root.appending(path: "fail-create")
        original = ["/Users/someone/Library/Keychains/login.keychain-db", root.appending(path: "Other/unrelated.keychain-db").path]
        try AppPaths.ensure(fake.deletingLastPathComponent())
        try (original.joined(separator: "\n") + "\n").write(to: state, atomically: true, encoding: .utf8)
        try Self.script(state: state, failMarker: failMarker, delay: "0.4").write(to: fake, atomically: true, encoding: .utf8)
        _ = chmod(fake.path, 0o755)
    }

    static func script(state: URL, failMarker: URL, delay: String) -> String {
        """
        #!/bin/sh
        STATE='\(state.path)'
        cmd="$1"; shift
        case "$cmd" in
          list-keychains)
            [ "$1" = "-d" ] && shift 2
            if [ "$1" = "-s" ]; then
              shift
              : > "$STATE.$$"
              for p in "$@"; do printf '%s\\n' "$p" >> "$STATE.$$"; done
              mv "$STATE.$$" "$STATE"
            else
              while IFS= read -r p; do printf '    "%s"\\n' "$p"; done < "$STATE"
            fi ;;
          create-keychain)
            pw="$2"; path="$3"
            if [ -e "$path" ]; then echo "security: SecKeychainCreate $path: A keychain with the same name already exists." >&2; exit 48; fi
            dir=$(cd "$(dirname "$path")" && pwd -P) || exit 1
            printf '%s\\n' "$dir/$(basename "$path")" >> "$STATE"
            sleep \(delay)
            if [ -e '\(failMarker.path)' ]; then echo "security: SecKeychainCreate $path: fake failure" >&2; exit 1; fi
            printf '%s' "$pw" > "$path" ;;
          unlock-keychain)
            pw="$2"; path="$3"
            if [ -f "$path" ] && [ "$(cat "$path")" = "$pw" ]; then exit 0; fi
            echo "security: SecKeychainUnlock $path: The user name or passphrase you entered is not correct." >&2; exit 51 ;;
          set-keychain-settings) ;;
          *) echo "fake security: unsupported $cmd" >&2; exit 2 ;;
        esac
        """
    }

    func box(_ name: String) -> BoxPaths { BoxPaths(url: root.appending(path: "Boxes/\(name).box")) }

    func fakeSearchList() throws -> [String] {
        try String(contentsOf: state, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// 真实的搜索列表，只读
    static func realSearchList() async throws -> String {
        try await Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).output
    }

    /// 在假 security 下运行；先确认确实换掉了，免得测试去动真实的搜索列表
    func withFakeSecurity(_ work: () async throws -> Void) async throws {
        let before = try await Self.realSearchList()
        defer { try? FileManager.default.removeItem(at: root) }
        try await BoxKeychain.$security.withValue(fake.path) {
            try #require(BoxKeychain.security == fake.path)
            try await work()
        }
        #expect(try await Self.realSearchList() == before, "真实的钥匙串搜索列表不能有任何变化")
    }

    @Test("创建钥匙串后只拿掉新加进搜索列表的那一项（按真实路径比较），其余原样保留")
    func createRestoresSearchList() async throws {
        try await withFakeSecurity {
            let paths = box("A")
            try await BoxKeychain.prepare(paths)
            #expect(try fakeSearchList() == original)
            #expect(FileManager.default.fileExists(atPath: paths.boxKeychain.path))
            #expect(FileOps.isSymlink(paths.loginKeychainLink))
            // 已经能解锁：不再创建
            try await BoxKeychain.prepare(paths)
            #expect(try fakeSearchList() == original)
        }
    }

    @Test("两次创建交错（导入的同时打开清除过数据的盒子）：盒子钥匙串不会留在搜索列表里")
    func overlappingCreates() async throws {
        // create-keychain 把新钥匙串加进列表后多等一会儿，留出足够的时间让第二次创建插进来
        try Self.script(state: state, failMarker: failMarker, delay: "1.5").write(to: fake, atomically: true, encoding: .utf8)
        try await withFakeSecurity {
            let first = box("A"), second = box("B")
            async let a: Void = BoxKeychain.prepare(first)
            // 等第一次的 create-keychain 已经把钥匙串加进列表（还没结束），再开始第二次。
            // 旧的做法这时读到的“原列表”里已经有 A，最后写回去，A 就永远留在了列表里
            let clock = ContinuousClock(), deadline = clock.now + .seconds(10)
            while try fakeSearchList().count == original.count, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            async let b: Void = BoxKeychain.prepare(second)
            _ = try await (a, b)
            #expect(try fakeSearchList() == original)
            #expect(FileManager.default.fileExists(atPath: first.boxKeychain.path))
            #expect(FileManager.default.fileExists(atPath: second.boxKeychain.path))
        }
    }

    @Test("create-keychain 失败（已经把新钥匙串加进了列表）：报错，搜索列表照样恢复")
    func failedCreateStillCleansUp() async throws {
        try await withFakeSecurity {
            try Data().write(to: failMarker)
            let error = await #expect(throws: MacBoxError.self) { try await BoxKeychain.prepare(box("A")) }
            #expect(error?.message.contains("fake failure") == true)
            #expect(try fakeSearchList() == original)
        }
    }

    @Test("盒子一辈子只用一个密码：清除数据后新建的钥匙串沿用原密码，之前的还原点还原后照样能解锁")
    func passwordSurvivesClearData() async throws {
        try await withFakeSecurity {
            let paths = box("A")
            try await BoxKeychain.prepare(paths)
            let password = try String(contentsOf: paths.keychainPassword, encoding: .utf8)
            // 还原点：保存 Home（里面有钥匙串）
            let saved = root.appending(path: "RestorePoint-Home")
            try FileManager.default.copyItem(at: paths.home, to: saved)

            // 清除数据：Home 没了，下次打开新建钥匙串
            try FileManager.default.removeItem(at: paths.home)
            try await BoxKeychain.prepare(paths)
            #expect(try String(contentsOf: paths.keychainPassword, encoding: .utf8) == password)

            // 还原到清除之前的还原点：旧钥匙串用同一个密码，直接解锁，不需要换新的
            try FileManager.default.removeItem(at: paths.home)
            try FileManager.default.copyItem(at: saved, to: paths.home)
            try await BoxKeychain.prepare(paths)
            let unusable = FileOps.contents(of: paths.keychains).filter { $0.lastPathComponent.hasPrefix("box-unusable") }
            #expect(unusable.isEmpty, "旧钥匙串应该能用同一个密码解锁")
            #expect(try fakeSearchList() == original)
        }
    }

    @Test("密码文件是指向盒子外的符号链接时不读它，换成新密码")
    func passwordSymlinkIsNotFollowed() async throws {
        try await withFakeSecurity {
            let paths = box("A")
            let secret = root.appending(path: "outside-secret")
            try "do-not-read".write(to: secret, atomically: true, encoding: .utf8)
            try AppPaths.ensure(paths.url)
            try FileManager.default.createSymbolicLink(at: paths.keychainPassword, withDestinationURL: secret)

            try await BoxKeychain.prepare(paths)

            #expect(!FileOps.isSymlink(paths.keychainPassword))
            #expect(try String(contentsOf: paths.keychainPassword, encoding: .utf8) != "do-not-read")
            #expect(try String(contentsOf: secret, encoding: .utf8) == "do-not-read")
            #expect(try String(contentsOf: paths.boxKeychain, encoding: .utf8) != "do-not-read")
        }
    }

    @Test("启动时清理：拿掉真实路径在盒子目录下的项（包括已删除盒子留下的），其他钥匙串不动")
    func sweepStaleEntries() async throws {
        try await withFakeSecurity {
            let boxes = root.appending(path: "Boxes")
            let existing = box("Y")
            try AppPaths.ensure(existing.keychains)
            try Data("x".utf8).write(to: existing.boxKeychain)
            let stale = [
                boxes.appending(path: "X.box/Home/Library/Keychains/box.keychain-db").path, // 盒子已删除，按 /var/… 写法
                FileOps.realPath(existing.boxKeychain.deletingLastPathComponent()) + "/box.keychain-db", // /private/var/… 写法
            ]
            // 名字以 Boxes 开头、但不在 Boxes 目录里的，不算
            let sibling = root.appending(path: "Boxes-other/z.keychain-db").path
            let seeded = [original[0], stale[0], original[1], stale[1], sibling]
            try (seeded.joined(separator: "\n") + "\n").write(to: state, atomically: true, encoding: .utf8)

            await BoxKeychain.removeStaleSearchListEntries(under: boxes)
            #expect(try fakeSearchList() == [original[0], original[1], sibling])

            // 防呆：根目录、包含你自己钥匙串的目录，什么也不做
            try (seeded.joined(separator: "\n") + "\n").write(to: state, atomically: true, encoding: .utf8)
            await BoxKeychain.removeStaleSearchListEntries(under: URL(fileURLWithPath: "/"))
            await BoxKeychain.removeStaleSearchListEntries(under: AppPaths.realHome)
            #expect(try fakeSearchList() == seeded)
        }
    }
}
