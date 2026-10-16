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
                    ReportContent(report: report, icon: box.icon)
                        .padding(24)
                }
            } else {
                ContentUnavailableView(L("还没有运行报告", "No Run Reports Yet"), systemImage: "doc.text.magnifyingglass",
                                       description: Text(L("在本机隔离中打开一次应用，退出后这里就有一份报告。",
                                                           "Open the app once in Native Isolation, and a report appears here after it quits.")))
                    .frame(maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                if reports.count > 1 {
                    Picker(L("哪一次", "Run"), selection: Binding(get: { report?.id }, set: { selection = $0 })) {
                        ForEach(reports) { Text(Self.label(for: $0)).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(L("以前的运行报告（每个应用留最近 \(RunReport.kept) 份）",
                            "Earlier run reports (the latest \(RunReport.kept) are kept for each app)"))
                }
                Spacer()
                if let report {
                    Menu(L("导出", "Export")) {
                        Button(L("拷贝文字", "Copy as Text")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.markdown(), forType: .string)
                        }
                        Button(L("存储为 Markdown…", "Save as Markdown…")) { saveMarkdown(report) }
                        Button(L("存储为图片…", "Save as Image…")) { saveImage(report) }
                    }
                    .fixedSize()
                    ShareLink(item: ReportImage(report: report, appURL: box.appURL),
                              preview: SharePreview(ReportImage.fileName(report), image: Image(nsImage: box.icon))) {
                        Label(L("分享图片", "Share Image"), systemImage: "square.and.arrow.up")
                    }
                    .help(L("把报告做成一张图片分享出去", "Share the report as an image"))
                }
                Button(L("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 700, height: 740)
        // 刚结束的一次存好之后重新读一遍
        .task(id: box.report?.endedAt) { saved = await box.savedReports() }
    }

    /// 选择器里的一项：开始时间 · 运行了多久
    static func label(for report: RunReport) -> String {
        let start = report.startedAt.formatted(date: .abbreviated, time: .shortened)
        return report.isRunning ? L("\(start)（运行中）", "\(start) (running)") : "\(start) · \(report.durationText)"
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
                throw MacBoxError(L("无法生成图片", "Couldn’t create the image"))
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
    let icon: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ReportStats(report: report)
            filesSection
            preferencesSection
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
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("「\(report.appName)」运行报告", "Run Report: \(report.appName)"))
                    .font(.title2.weight(.semibold))
                Text(report.timeText)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Tag(text: report.networkBlocked ? L("不联网", "Offline") : L("允许联网", "Network Allowed"),
                        systemImage: report.networkBlocked ? "network.slash" : "network")
                    Tag(text: report.sharesDownloads ? L("共享「下载」", "Downloads Shared") : L("不共享「下载」", "Downloads Not Shared"),
                        systemImage: "arrow.down.circle")
                    if report.isRunning { Tag(text: L("运行中，记录中", "Running, recording"), systemImage: "record.circle", tint: .green) }
                }
            }
        }
    }

    // MARK: 文件

    @ViewBuilder
    private var filesSection: some View {
        ReportSection(title: L("写入的文件", "Files Written"), systemImage: "doc.on.doc") {
            if let files = report.files, let totals = report.fileTotals {
                if files.isEmpty {
                    Placeholder(L("没有写入文件。", "No files were written."))
                } else {
                    Text(L("新建 \(totals.created)、修改 \(totals.modified)、删除 \(totals.deleted)，共 \(FileOps.formatBytes(totals.bytes))。路径是应用眼里的位置，实际都写进了 MacBox 的盒子（「下载」除外）。",
                           "\(totals.created) created, \(totals.modified) modified, \(totals.deleted) deleted, \(FileOps.formatBytes(totals.bytes)) in total. Paths are where the app thinks it wrote; everything actually went into the MacBox box (except Downloads)."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { FileAreaRow(area: $0) }
                    }
                }
            } else {
                Placeholder(report.isRunning ? L("应用退出后统计。", "Counted after the app quits.") : L("没能统计。", "Couldn’t be counted."))
            }
        }
    }

    // MARK: 设置

    @ViewBuilder
    private var preferencesSection: some View {
        ReportSection(title: L("修改的设置", "Settings Changed"), systemImage: "slider.horizontal.3") {
            if let preferences = report.preferences {
                if preferences.isEmpty {
                    Placeholder(L("没有改动偏好设置。", "No preferences were changed."))
                } else {
                    Text(L("只记设置项的名字，不记内容。运行时借给系统，退出后都收回了盒子里。",
                           "Only the names of the settings are recorded, not their values. They were lent to the system while the app ran and returned to the box afterwards."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(preferences) { PreferenceRow(change: $0) }
                }
            } else {
                Placeholder(report.isRunning ? L("应用退出后统计。", "Counted after the app quits.")
                                             : L("偏好设置没能收回，这次没有统计。", "Preferences couldn’t be returned, so they weren’t counted."))
            }
        }
    }

    // MARK: 服务器

    @ViewBuilder
    private var serversSection: some View {
        ReportSection(title: L("连接的服务器", "Servers Contacted"), systemImage: "network") {
            if report.networkBlocked {
                Placeholder(L("这次运行不允许联网。", "Network access was blocked for this run."))
            } else if report.servers.isEmpty {
                Placeholder(report.isRunning ? L("还没有看到网络连接。", "No network connections seen yet.")
                                             : L("没有看到网络连接。", "No network connections were seen."))
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
        ReportSection(title: L("启动的程序", "Programs Launched"), systemImage: "terminal") {
            if report.programs.isEmpty {
                Placeholder(L("没有看到启动程序。", "No program launches were seen."))
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
        ReportSection(title: L("被拦下的行为", "Blocked Attempts"), systemImage: "hand.raised") {
            if report.blocks.isEmpty {
                Placeholder(L("没有记录到被拦下的行为。", "No blocked attempts were recorded."))
            } else {
                ForEach(report.blocks) { block in
                    ReportRow(title: block.kind.title, detail: block.targetText, trailing: block.count > 1 ? "×\(block.count)" : nil,
                              tint: block.kind.suggestsVirtualMac ? .orange : nil)
                }
            }
        }
    }
}

/// 五个数字：文件、设置、服务器、程序、拦截
private struct ReportStats: View {
    let report: RunReport

    var body: some View {
        HStack(spacing: 10) {
            Stat(value: report.fileTotals.map { "\($0.count)" } ?? "–", label: L("写入文件", "Files Written"))
            Stat(value: report.preferenceKeyCount.map { "\($0)" } ?? "–", label: L("改动设置", "Settings Changed"))
            Stat(value: report.networkBlocked ? L("断网", "Off") : "\(report.servers.count)", label: L("连接服务器", "Servers"))
            Stat(value: "\(report.programs.count)", label: L("启动程序", "Programs"))
            Stat(value: "\(report.blockCount)", label: L("被拦下", "Blocked"),
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
                Text(label).font(.caption).foregroundStyle(.secondary)
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
        if area.totals.created > 0 { parts.append(L("新建 \(area.totals.created)", "\(area.totals.created) created")) }
        if area.totals.modified > 0 { parts.append(L("修改 \(area.totals.modified)", "\(area.totals.modified) modified")) }
        if area.totals.deleted > 0 { parts.append(L("删除 \(area.totals.deleted)", "\(area.totals.deleted) deleted")) }
        let counts = parts.joined(separator: L("、", ", "))
        guard !area.examples.isEmpty else { return counts }
        return counts + L("：", ": ") + area.examples.joined(separator: L("、", ", "))
    }
}

private struct PreferenceRow: View {
    let change: PreferenceChange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(change.domain)
                if change.isNew { Tag(text: L("新建", "New"), systemImage: "plus") }
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 5)
    }

    private var lines: [String] {
        let separator = L("、", ", ")
        return [
            change.added.isEmpty ? nil : L("新增 \(change.added.count) 项：", "\(change.added.count) added: ") + change.added.joined(separator: separator),
            change.changed.isEmpty ? nil : L("修改 \(change.changed.count) 项：", "\(change.changed.count) changed: ") + change.changed.joined(separator: separator),
            change.removed.isEmpty ? nil : L("删除 \(change.removed.count) 项：", "\(change.removed.count) removed: ") + change.removed.joined(separator: separator),
        ].compactMap { $0 }
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
                    throw MacBoxError(L("无法生成图片", "Couldn’t create the image"))
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
        return L("「\(report.appName)」运行报告 \(day)", "\(report.appName) Run Report \(day)")
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
                    Text(L("运行一次「\(report.appName)」，它想在你的 Mac 上做这些",
                           "Run “\(report.appName)” once, and here’s what it tried to do on your Mac"))
                        .font(.system(size: 20, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text([report.version.map { L("版本 \($0)", "Version \($0)") }, report.timeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ReportStats(report: report)
            if let files = report.files, !files.isEmpty {
                CardList(title: L("写入最多的位置", "Where it wrote the most"),
                         rows: files.prefix(5).map { ($0.path, FileOps.formatBytes($0.totals.bytes)) })
            }
            if let preferences = report.preferences, !preferences.isEmpty {
                CardList(title: L("改动的设置", "Settings changed"),
                         rows: preferences.prefix(3).map { ($0.domain, L("\($0.added.count + $0.changed.count + $0.removed.count) 项", "\($0.added.count + $0.changed.count + $0.removed.count)")) })
            }
            if !report.networkBlocked, !report.servers.isEmpty {
                CardList(title: L("连接的服务器", "Servers contacted"),
                         rows: report.servers.prefix(6).map { ($0.title, $0.place) }, more: report.servers.count - 6)
            }
            if !report.programs.isEmpty {
                CardList(title: L("启动的程序", "Programs launched"),
                         rows: report.programs.prefix(5).map { ($0.path, $0.note ?? "") }, more: report.programs.count - 5)
            }
            if !report.blocks.isEmpty {
                CardList(title: L("被 MacBox 拦下", "Blocked by MacBox"),
                         rows: report.blocks.prefix(5).map { ($0.kind.title, $0.targetText) }, more: report.blocks.count - 5)
            }
            Divider()
            HStack {
                Text(L("由 MacBox 隔离运行并记录", "Run in isolation and recorded by MacBox"))
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
                    Text(L("还有 \(more) 项", "and \(more) more")).font(.system(size: 11)).foregroundStyle(.secondary)
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
