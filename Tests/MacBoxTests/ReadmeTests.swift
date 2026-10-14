import Foundation
import Testing

/// README 里写的界面位置要和代码对得上：设置页的分区改了名、挪了地方，README 很容易忘了跟着改
/// （之前就写过并不存在的「设置 › 通用」「设置 › 虚拟 Mac」）。只读源文件，不碰任何真实数据
@Suite("README")
struct ReadmeTests {
    /// 仓库根目录：本文件在 Tests/MacBoxTests/ 下
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func source(_ relative: String) throws -> String {
        try String(contentsOf: repo.appending(path: relative), encoding: .utf8)
    }

    @Test("README 里的“设置 › X”都是设置页里真实存在的分区")
    func settingsPathsExist() throws {
        let readme = try source("README.md")
        let page = try source("Sources/MacBox/Views/SettingsPage.swift")
        // 分区标题有两种写法：Section(L("名称", …)) 和 header: { Text(L("名称", …)) }；
        // 分区里的某一行（如「存储」里的“虚拟 Mac”）不算，README 不能把它当成分区来指路
        let sections = Set(page.matches(of: /(?:Section\(|header:\s*\{\s*Text\()L\("([^"]+)"/).map { String($0.1) })
        // 分区名后面跟空格或标点（“设置 › 兼容性 里…”）；“系统设置 › …”说的是 macOS 的系统设置，跳过
        let referenced = readme.matches(of: /(系统)?设置 › ([^\s，。、；：（）›*]+)/)
            .filter { $0.1 == nil }
            .map { String($0.2) }

        #expect(sections.contains("兼容性"), "没找到设置页的分区标题，匹配规则可能需要更新：\(sections.sorted())")
        #expect(!referenced.isEmpty)
        for name in referenced {
            #expect(sections.contains(name), "README 写了「设置 › \(name)」，但设置页没有这个分区（现有：\(sections.sorted())）")
        }
    }
}
