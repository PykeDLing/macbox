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

    /// README 里每处“设置 › ”之后的文字（到行尾）。“系统设置 › …”说的是 macOS 的系统设置，跳过。
    /// 只认“设置 › ”这个标记、不去截取分区名：分区名可以带空格（“虚拟 Mac”），
    /// 后面也不一定跟空格或标点，按空白、标点截断都会截错
    static func settingsReferences(in readme: String) -> [Substring] {
        readme.matches(of: #/(系统)?设置 › /#)
            .filter { $0.1 == nil }
            .map { readme[$0.range.upperBound...].prefix { $0 != "\n" } }
    }

    /// 对不上任何分区的引用：“设置 › ”之后的文字不以哪个分区名开头。返回前 20 个字符，用在失败信息里
    static func unknownSettingsReferences(in readme: String, sections: Set<String>) -> [String] {
        settingsReferences(in: readme)
            .filter { rest in !sections.contains { rest.hasPrefix($0) } }
            .map { String($0.prefix(20)) }
    }

    @Test("README 里的“设置 › X”都是设置页里真实存在的分区")
    func settingsPathsExist() throws {
        let readme = try source("README.md")
        let page = try source("Sources/MacBox/Views/SettingsPage.swift")
        // 分区标题有两种写法：Section("名称") 和 header: { Text("名称") }；
        // 分区里的某一行（如「存储」里的“虚拟 Mac”）不算，README 不能把它当成分区来指路
        let sections = Set(page.matches(of: /(?:Section\(|header:\s*\{\s*Text\()"([^"]+)"/).map { String($0.1) })

        #expect(sections.contains("兼容性"), "没找到设置页的分区标题，匹配规则可能需要更新：\(sections.sorted())")
        #expect(!Self.settingsReferences(in: readme).isEmpty)
        for reference in Self.unknownSettingsReferences(in: readme, sections: sections) {
            Issue.record("README 写了「设置 › \(reference)…」，但设置页没有这个分区（现有：\(sections.sorted())）")
        }
    }

    @Test("分区名带空格、后面不跟空格也认得出；系统设置不算")
    func referenceMatching() {
        let readme = """
        在 设置 › 虚拟 Mac 里删除。到 系统设置 › 隐私与安全性 打开。
        处理方式在 设置 › 通用 里选择，语言在 设置 › 语言里切换
        """
        #expect(Self.settingsReferences(in: readme).count == 3)
        let unknown = Self.unknownSettingsReferences(in: readme, sections: ["虚拟 Mac", "语言"])
        #expect(unknown.count == 1)
        #expect(unknown.first?.hasPrefix("通用 里选择") == true)
        #expect(Self.unknownSettingsReferences(in: readme, sections: ["虚拟 Mac", "语言", "通用"]).isEmpty)
    }
}
