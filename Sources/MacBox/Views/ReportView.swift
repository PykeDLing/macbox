import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// 运行报告：这次（或以前某次）运行写了哪些文件、改了哪些设置、连了哪些服务器、启动了哪些程序、哪些行为被拦下。
/// 可以拷贝成文字、存储为 Markdown 或图片、直接分享图片
struct ReportView: View {
    let box: Box
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [RunReport] = []
    @State private var selection: UUID?
    /// 点了「收进盒子…」、等确认的：哪一项、列在哪一份报告里
    @State private var adopting: (stray: StrayPreference, report: RunReport)?
    @State private var adoptionError: String?

    /// 运行中的（还没存）放在最前；存过的里面同一次的以内存里的为准
    private var reports: [RunReport] {
        var list = saved
        if let current = box.currentReport {
            list.removeAll { $0.id == current.id }
            list.insert(current, at: 0)
        }
        return list
    }

    private var report: RunReport? { reports.first { $0.id == selection } ?? reports.first }

    var body: some View {
        VStack(spacing: 0) {
            if let report {
                ScrollView {
                    ReportContent(report: report, box: box) { adopting = ($0, report) }
                        .padding(24)
                }
            } else {
                ContentUnavailableView(String(localized: "还没有运行报告"), systemImage: "doc.text.magnifyingglass",
                                       description: Text("在本机隔离中打开一次应用，退出后这里就有一份报告。"))
                    .frame(maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                if reports.count > 1 {
                    Picker("哪一次", selection: Binding(get: { report?.id }, set: { selection = $0 })) {
                        ForEach(reports) { Text(Self.label(for: $0)).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("以前的运行报告（每个应用留最近 \(RunReport.kept) 份）")
                }
                Spacer()
                if let report {
                    Menu(String(localized: "导出")) {
                        Button("拷贝文字") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.markdown(), forType: .string)
                        }
                        Button("存储为 Markdown…") { saveMarkdown(report) }
                        Button("存储为图片…") { saveImage(report) }
                    }
                    .fixedSize()
                    ShareLink(item: ReportImage(report: report, appURL: box.appURL),
                              preview: SharePreview(ReportImage.fileName(report), image: Image(nsImage: box.icon))) {
                        Label("分享图片", systemImage: "square.and.arrow.up")
                    }
                    .help("把报告做成一张图片分享出去")
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 700, height: 740)
        // 刚结束的一次存好之后重新读一遍
        .task(id: box.report?.endedAt) { saved = await box.savedReports() }
        // 域名放在说明里：标题字大，长域名会在中间断开
        .confirmationDialog("把这项设置收进盒子？",
                            isPresented: Binding(get: { adopting != nil }, set: { if !$0 { adopting = nil } }),
                            presenting: adopting) { pending in
            Button("收进盒子") {
                Task {
                    do {
                        try await box.adoptStrayPreference(pending.stray.domain, listedIn: pending.report)
                    } catch {
                        adoptionError = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { pending in
            let domain = pending.stray.domain
            Text("「\(domain)」会从这台 Mac 的偏好设置移进盒子（名字以它开头的也一起），以后只在应用运行时借出，删除盒子时一起删除。\n\n如果它其实属于别的程序，那个程序就读不到它了。")
        }
        .alert("没能收进盒子",
               isPresented: Binding(get: { adoptionError != nil }, set: { if !$0 { adoptionError = nil } })) {
            Button("好") {}
        } message: {
            Text(adoptionError ?? "")
        }
    }

    /// 选择器里的一项：开始时间 · 运行了多久
    static func label(for report: RunReport) -> String {
        let start = report.startedAt.formatted(date: .abbreviated, time: .shortened)
        return report.isRunning ? String(localized: "\(start)（运行中）") : "\(start) · \(report.durationText)"
    }

    private func saveMarkdown(_ report: RunReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = ReportImage.baseName(report) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.markdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func saveImage(_ report: RunReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ReportImage.fileName(report)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = ReportImage.png(report, icon: box.icon) else {
                throw MacBoxError(String(localized: "无法生成图片"))
            }
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - 报告内容

/// 报告页的正文
private struct ReportContent: View {
    let report: RunReport
    let box: Box
    /// 点了某一项写在盒子外的设置的「收进盒子…」
    let onAdopt: (StrayPreference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ReportStats(report: report, strayPending: report.strayPreferences?.contains { box.status(of: $0) == .adoptable })
            filesSection
            preferencesSection
            straysSection
            serversSection
            programsSection
            blocksSection
            Text(RunReport.caveats)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: box.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("「\(report.appName)」运行报告")
                    .font(.title2.weight(.semibold))
                Text(report.timeText)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Tag(text: report.networkBlocked ? String(localized: "不联网") : String(localized: "可以联网"),
                        systemImage: report.networkBlocked ? "network.slash" : "network")
                    Tag(text: report.sharesDownloads ? String(localized: "共享「下载」") : String(localized: "不共享「下载」"),
                        systemImage: "arrow.down.circle")
                    if let folders = report.writableFolders {
                        Tag(text: String(localized: "可写入 \(folders.count) 个文件夹"),
                            systemImage: "folder")
                            .help(folders.joined(separator: "\n"))
                    }
                    if report.isRunning { Tag(text: String(localized: "运行中，记录中"), systemImage: "record.circle", tint: .green) }
                }
            }
        }
    }

    // MARK: 文件

    @ViewBuilder
    private var filesSection: some View {
        ReportSection(title: String(localized: "写入的文件"), systemImage: "doc.on.doc") {
            if let files = report.files, let totals = report.fileTotals {
                if files.isEmpty {
                    Placeholder(String(localized: "没有写入文件。"))
                } else {
                    Text(report.filesSummary(totals))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { FileAreaRow(area: $0) }
                    }
                }
            } else {
                Placeholder(report.isRunning ? String(localized: "应用退出后统计。") : String(localized: "没能统计。"))
            }
        }
    }

    // MARK: 设置

    @ViewBuilder
    private var preferencesSection: some View {
        ReportSection(title: String(localized: "修改的设置"), systemImage: "slider.horizontal.3") {
            if let preferences = report.preferences {
                if preferences.isEmpty {
                    Placeholder(String(localized: "没有改动偏好设置。"))
                } else {
                    Text("只记设置项的名字，不记内容。运行时借给系统，退出后都收回了盒子里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(preferences) { PreferenceRow(change: $0) }
                }
            } else {
                Placeholder(report.isRunning ? String(localized: "应用退出后统计。")
                                             : String(localized: "偏好设置没能收回，这次没有统计。"))
            }
        }
    }

    // MARK: 写在盒子外的设置

    @ViewBuilder
    private var straysSection: some View {
        ReportSection(title: RunReport.strayTitle, systemImage: "exclamationmark.triangle") {
            if let strays = report.strayPreferences {
                if strays.isEmpty {
                    Placeholder(String(localized: "没有发现。"))
                } else {
                    Text(RunReport.strayExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(strays) { stray in
                        StrayRow(stray: stray, status: box.status(of: stray), canAdopt: box.activity == .idle) { onAdopt(stray) }
                    }
                }
            } else {
                Placeholder(report.isRunning ? String(localized: "应用退出后统计。")
                                             : String(localized: "旧版 MacBox 的报告没有这一项。"))
            }
        }
    }

    // MARK: 服务器

    @ViewBuilder
    private var serversSection: some View {
        ReportSection(title: String(localized: "连接的服务器"), systemImage: "network") {
            if report.networkBlocked {
                Placeholder(String(localized: "这次运行不允许联网。"))
            } else if report.servers.isEmpty {
                Placeholder(report.isRunning ? String(localized: "还没有看到网络连接。")
                                             : String(localized: "没有看到网络连接。"))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(report.servers) { ServerRow(server: $0) }
                }
            }
        }
    }

    // MARK: 程序

    @ViewBuilder
    private var programsSection: some View {
        ReportSection(title: String(localized: "启动的程序"), systemImage: "terminal") {
            if report.programs.isEmpty {
                Placeholder(String(localized: "没有看到启动程序。"))
            } else {
                ForEach(report.programs) { program in
                    ReportRow(title: program.path, detail: program.note,
                              trailing: program.count > 1 ? "×\(program.count)" : nil)
                }
            }
        }
    }

    // MARK: 拦截

    @ViewBuilder
    private var blocksSection: some View {
        ReportSection(title: String(localized: "被拦下的行为"), systemImage: "hand.raised") {
            if report.blocks.isEmpty {
                Placeholder(String(localized: "没有记录到被拦下的行为。"))
            } else {
                ForEach(report.blocks) { block in
                    ReportRow(title: block.kind.title, detail: block.targetText, trailing: block.count > 1 ? "×\(block.count)" : nil,
                              tint: block.kind.suggestsVirtualMac ? .orange : nil)
                }
            }
        }
    }
}

/// 五个数字：文件、设置、服务器、程序、拦截；有写在盒子外的设置时，设置后面再加一个
private struct ReportStats: View {
    let report: RunReport
    /// 写在盒子外的设置里还有没收进盒子的：那个数字标成橙色。nil（分享图片，没有盒子可查）时只要有就标
    var strayPending: Bool?

    var body: some View {
        HStack(spacing: 10) {
            Stat(value: report.fileTotals.map { "\($0.count)" } ?? "–", label: String(localized: "写入文件"))
            Stat(value: report.preferenceKeyCount.map { "\($0)" } ?? "–", label: String(localized: "改动设置"))
            if let strays = report.strayPreferences, !strays.isEmpty {
                Stat(value: "\(strays.count)", label: String(localized: "写在盒子外"), tint: strayPending ?? true ? .orange : nil)
            }
            Stat(value: report.networkBlocked ? String(localized: "断网") : "\(report.servers.count)", label: String(localized: "report.stat.servers", defaultValue: "连接服务器", comment: "报告统计格子的标签，要短"))
            Stat(value: "\(report.programs.count)", label: String(localized: "report.stat.programs", defaultValue: "启动程序", comment: "报告统计格子的标签，要短"))
            Stat(value: "\(report.blockCount)", label: String(localized: "被拦下"),
                 tint: report.blocks.contains(where: \.kind.suggestsVirtualMac) ? .orange : nil)
        }
    }

    private struct Stat: View {
        let value: String
        let label: String
        var tint: Color?

        var body: some View {
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint ?? .primary)
                    .monospacedDigit()
                // 六个数字时格子变窄，英文的标签放不下就缩小一点，不截断
                Text(label).font(.caption).foregroundStyle(.secondary).minimumScaleFactor(0.8)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct ReportSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
    }
}

private struct Placeholder: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

/// 一行：标题、说明（可选）、右侧的数字
private struct ReportRow: View {
    let title: String
    var detail: String?
    var trailing: String?
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 5)
        .help([title, detail].compactMap { $0 }.joined(separator: "\n"))
    }
}

private struct FileAreaRow: View {
    let area: FileArea

    var body: some View {
        ReportRow(title: area.path, detail: detail, trailing: FileOps.formatBytes(area.totals.bytes))
    }

    private var detail: String {
        var parts: [String] = []
        if area.totals.created > 0 { parts.append(String(localized: "新建 \(area.totals.created)")) }
        if area.totals.modified > 0 { parts.append(String(localized: "修改 \(area.totals.modified)")) }
        if area.totals.deleted > 0 { parts.append(String(localized: "删除 \(area.totals.deleted)")) }
        let counts = parts.joined(separator: String(localized: "、"))
        guard !area.examples.isEmpty else { return counts }
        return counts + String(localized: "：") + area.examples.joined(separator: String(localized: "、"))
    }
}

private struct PreferenceRow: View {
    let change: PreferenceChange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(change.domain)
                if change.isNew { Tag(text: String(localized: "新建"), systemImage: "plus") }
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 5)
    }

    private var lines: [String] {
        let separator = String(localized: "、")
        return [
            change.added.isEmpty ? nil : String(localized: "新增 \(change.added.count) 项：") + change.added.joined(separator: separator),
            change.changed.isEmpty ? nil : String(localized: "修改 \(change.changed.count) 项：") + change.changed.joined(separator: separator),
            change.removed.isEmpty ? nil : String(localized: "删除 \(change.removed.count) 项：") + change.removed.joined(separator: separator),
        ].compactMap { $0 }
    }
}

/// 一项写在盒子外的设置：域名、设置项的名字，可以收进盒子的有按钮
private struct StrayRow: View {
    let stray: StrayPreference
    let status: Box.StrayStatus
    /// 应用没在运行、盒子没在忙
    let canAdopt: Bool
    let onAdopt: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(stray.domain)
                    if stray.byHost { Tag(text: String(localized: "仅限本机"), systemImage: "desktopcomputer") }
                    if status == .adopted { Tag(text: String(localized: "已收进盒子"), systemImage: "checkmark", tint: .green) }
                }
                Text(stray.keys.isEmpty ? String(localized: "没有设置项")
                                        : String(localized: "\(stray.keys.count) 项：") + stray.keys.joined(separator: String(localized: "、")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                if case .listedOnly(let reason) = status {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if status == .adoptable {
                Button("收进盒子…", action: onAdopt)
                    .disabled(!canAdopt)
                    .help(canAdopt ? String(localized: "存进盒子，从这台 Mac 上删除，以后只在应用运行时借给系统")
                                   : String(localized: "请先退出应用"))
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ServerRow: View {
    let server: ServerContact

    var body: some View {
        ReportRow(title: server.title, detail: detail)
    }

    private var detail: String {
        [server.place, server.transport.uppercased(), server.process, server.firstSeen.formatted(date: .omitted, time: .standard)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct Tag: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - 分享用的图片

/// 分享出去的图片：一张卡片，放概要和每类的前几项。分享时才生成
struct ReportImage: Transferable {
    let report: RunReport
    let appURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            let data = try await MainActor.run {
                guard let data = png(item.report, icon: AppIcon.load(item.appURL)) else {
                    throw MacBoxError(String(localized: "无法生成图片"))
                }
                return data
            }
            let folder = FileManager.default.temporaryDirectory.appending(path: "MacBox-Report-\(UUID().uuidString)")
            try AppPaths.ensure(folder)
            let url = folder.appending(path: fileName(item.report))
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /// 「夸克网盘」运行报告 2026-10-15
    static func baseName(_ report: RunReport) -> String {
        let day = report.startedAt.formatted(.iso8601.year().month().day())
        return String(localized: "「\(report.appName)」运行报告 \(day)")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    static func fileName(_ report: RunReport) -> String { baseName(report) + ".png" }

    /// 生成图片：浅色、2 倍分辨率
    @MainActor static func png(_ report: RunReport, icon: NSImage) -> Data? {
        let renderer = ImageRenderer(content: ReportCard(report: report, icon: icon).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// 分享用的卡片（固定宽度、浅色）
private struct ReportCard: View {
    let report: RunReport
    let icon: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行一次「\(report.appName)」，它想在你的 Mac 上做这些")
                        .font(.system(size: 20, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text([report.version.map { String(localized: "版本 \($0)") }, report.timeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ReportStats(report: report)
            if let files = report.files, !files.isEmpty {
                CardList(title: String(localized: "写入最多的位置"),
                         rows: files.prefix(5).map { ($0.path, FileOps.formatBytes($0.totals.bytes)) })
            }
            if let preferences = report.preferences, !preferences.isEmpty {
                CardList(title: String(localized: "改动的设置"),
                         rows: preferences.prefix(3).map { ($0.domain, String(localized: "\($0.added.count + $0.changed.count + $0.removed.count) 项")) })
            }
            if let strays = report.strayPreferences, !strays.isEmpty {
                CardList(title: String(localized: "可能是它写在盒子外的设置"),
                         rows: strays.prefix(3).map { ($0.domain, $0.byHost ? String(localized: "仅限本机") : String(localized: "\($0.keys.count) 项")) },
                         more: strays.count - 3)
            }
            if !report.networkBlocked, !report.servers.isEmpty {
                CardList(title: String(localized: "连接的服务器"),
                         rows: report.servers.prefix(6).map { ($0.title, $0.place) }, more: report.servers.count - 6)
            }
            if !report.programs.isEmpty {
                CardList(title: String(localized: "启动的程序"),
                         rows: report.programs.prefix(5).map { ($0.path, $0.note ?? "") }, more: report.programs.count - 5)
            }
            if !report.blocks.isEmpty {
                CardList(title: String(localized: "被 MacBox 拦下"),
                         rows: report.blocks.prefix(5).map { ($0.kind.title, $0.targetText) }, more: report.blocks.count - 5)
            }
            Divider()
            HStack {
                Text("由 MacBox 隔离运行并记录")
                Spacer(minLength: 12)
                Text("github.com/PykeDLing/macbox")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 640)
        .background(Color.white)
    }

    private struct CardList: View {
        let title: String
        let rows: [(String, String)]
        var more = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.0).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 10)
                        Text(row.1).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                }
                if more > 0 {
                    Text("还有 \(more) 项").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 详情面板里说“上次运行”是什么时候
enum RunReportLabel {
    static func time(_ report: RunReport) -> String {
        "\(report.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.durationText)"
    }
}
