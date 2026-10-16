import Foundation
import Testing
@testable import MacBox

extension BoxPaths {
    /// 盒子根目录下的这个名字被分进了哪几类（见 BoxPaths.writableItems）。每一项都应当恰好一类
    func classes(of name: String) -> [String] {
        [("App 可写", writableItems), ("MacBox 私有", privateItems), ("App 只能读", readOnlyItems)]
            .filter { $0.1.contains { $0.lastPathComponent == name } }
            .map(\.0)
    }
}

/// 盒子根目录下每一项属于哪一类只在 BoxPaths 里写一次，沙盒规则（SandboxProfile）和 MacBox 在沙盒外的检查
/// （IsolatedSession.checkLayout）都按它来。新增一项时漏了分类，App 就可能改到 MacBox 照着去删改沙盒外文件的记录，
/// 或者读到不该读的。这里只读源文件；真的走一遍添加、运行、建还原点之后的检查见 LifecycleTests.boxItemsAreClassified
@Suite("盒子布局")
struct BoxLayoutTests {
    let paths = BoxPaths(url: URL(fileURLWithPath: "/MacBoxTests/layout.box", isDirectory: true))
    /// 仓库根目录：本文件在 Tests/MacBoxTests/ 下
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("BoxPaths 里起了名字的每一项恰好属于一类；别处不在盒子根目录下另起名字")
    func everyDeclaredItemIsClassified() throws {
        let source = try String(contentsOf: repo.appending(path: "Sources/MacBox/Box/BoxConfig.swift"), encoding: .utf8)
        let declaration = try #require(source.range(of: "struct BoxPaths"))
        // url.appending(path: "Prefs/.lease.json") 也算 Prefs：只看第一级
        let declared = Set(source[declaration.lowerBound...].matches(of: /\burl\.appending\(path: "([^"\/]+)/).map { String($0.1) })
        #expect(declared.contains("box.json") && declared.contains(".keychain-password"), "没找到 BoxPaths 里的名字，匹配规则可能需要更新：\(declared.sorted())")
        for name in declared.sorted() {
            #expect(paths.classes(of: name).count == 1, "「\(name)」：\(paths.classes(of: name))")
        }
        let classified = paths.writableItems + paths.privateItems + paths.readOnlyItems
        #expect(Set(classified.map(\.lastPathComponent)) == declared)
        #expect(classified.allSatisfy { $0.deletingLastPathComponent().path == paths.url.path }, "分类里只放盒子根目录的直接子项")

        let sources = repo.appending(path: "Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "BoxConfig.swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.firstMatch(of: /\b(paths|box)\.url\.appending\(path: "/) == nil,
                    "\(file.lastPathComponent) 在盒子根目录下另起了名字：要在 BoxPaths 里声明并分类")
        }
    }

    @Test("骨架是可写的那几处，加上它们里面 MacBox 会顺着走的文件夹")
    func skeleton() {
        let writable = paths.writableItems.map(\.path)
        #expect(Set(writable).isSubset(of: paths.skeleton.map(\.path)))
        for folder in paths.skeleton {
            #expect(folder.hasDirectoryPath && writable.contains { folder.path == $0 || folder.path.hasPrefix($0 + "/") }, "\(folder.path)")
        }
    }
}
