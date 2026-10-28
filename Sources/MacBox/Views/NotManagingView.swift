import AppKit
import SwiftUI

/// 这次不管理盒子（见 Ownership）：另一个 MacBox 正在管理，或者锁文件打不开、确认不了。
/// 这里不显示、也不碰任何盒子，只说明情况。显示空的应用列表会让人以为盒子都没了
struct NotManagingView: View {
    @Environment(BoxStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if let location {
                Text(location)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if let unhandled = Self.describeUnhandled(store.unhandledOpens, ownership: store.ownership) {
                Label(unhandled, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 10) {
                Button(L("退出", "Quit")) { NSApp.terminate(nil) }
                switch store.ownership {
                case .otherProcess:
                    if let other = runningOther {
                        Button(L("切换过去", "Switch to It")) { switchTo(other) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                case .lockUnavailable(let file, _):
                    Button(L("在访达中显示", "Show in Finder")) { Self.reveal(file) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .thisProcess:
                    EmptyView()
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if case .lockUnavailable = store.ownership {
            return L("无法确认只有这一个 MacBox 在管理盒子", "MacBox Can’t Make Sure It’s the Only One Managing the Boxes")
        }
        return L("另一个 MacBox 正在管理这些盒子", "Another MacBox Is Managing These Boxes")
    }

    private var explanation: String {
        if case .lockUnavailable(_, let reason) = store.ownership {
            let reason = BoxStore.withoutFinalPeriod(reason)
            return L("MacBox 用下面这个文件确认同一时间只有一个 MacBox 在管理盒子，但它打不开（\(reason)）。为了不和可能正在运行的另一个 MacBox 冲突，这次先不管理盒子。删除这个文件，再重新打开 MacBox 就好。",
                     "MacBox uses the file below to make sure only one MacBox manages the boxes at a time, but the file can’t be opened (\(reason)). To avoid conflicting with another MacBox that may be running, this one won’t manage the boxes. Delete the file, then open MacBox again.")
        }
        return L("同一时间只能由一个 MacBox 管理盒子：两个一起运行时，会互相结束对方打开的应用、收回对方借出的设置。请使用正在运行的那个。",
                 "Only one MacBox can manage the boxes at a time. If two ran together, each would quit the apps the other opened and take back the settings the other lent out. Use the one that’s already running.")
    }

    /// 正在管理的那个 MacBox 在哪里，或者打不开的锁文件在哪里
    private var location: String? {
        switch store.ownership {
        case .otherProcess(let holder?):
            // 系统说的 App 包位置优先，锁文件里写的只是参考
            let path = runningOther?.bundleURL?.path ?? holder.path
            return Self.describe(path: path, version: holder.version)
        case .lockUnavailable(let file, _):
            return (file.path as NSString).abbreviatingWithTildeInPath
        default:
            return nil
        }
    }

    /// 拿着锁的那个进程，是一个正在运行的 MacBox 时（可以切过去）
    private var runningOther: NSRunningApplication? {
        guard case .otherProcess(let holder?) = store.ownership,
              let app = NSRunningApplication(processIdentifier: holder.pid), !app.isTerminated,
              app.bundleIdentifier == Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    /// 切到正在管理盒子的那个，这个退出：留着也什么都做不了
    private func switchTo(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate()
        NSApp.terminate(nil)
    }

    /// 锁文件不存在（数据目录都建不了）时显示它所在的文件夹
    private static func reveal(_ file: URL) {
        let existing = FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([existing])
    }

    static func describe(path: String, version: String?) -> String {
        let path = (path as NSString).abbreviatingWithTildeInPath
        if let version {
            return L("正在运行的是：\(path)（版本 \(version)）", "The one running: \(path) (version \(version))")
        }
        return L("正在运行的是：\(path)", "The one running: \(path)")
    }

    /// 没有处理的打开请求：拖进来的文件写名字，启动器（macbox:// 的 URL）只说“从聚焦打开的应用”，ID 对人没有意义
    static func describeUnhandled(_ urls: [URL], ownership: Ownership) -> String? {
        guard !urls.isEmpty else { return nil }
        let files = urls.filter(\.isFileURL).map(\.lastPathComponent)
        let launchers = urls.count - files.count
        var chinese = files.isEmpty ? "" : BoxStore.chineseList(files)
        var english = files.isEmpty ? "" : BoxStore.englishList(files)
        if launchers > 0 {
            chinese += (chinese.isEmpty ? "" : "和") + "从聚焦打开的应用"
            english += (english.isEmpty ? "" : " and ") + (launchers == 1 ? "an app opened from Spotlight" : "apps opened from Spotlight")
        }
        let it = urls.count == 1 ? "it" : "them"
        let advice = if case .lockUnavailable = ownership {
            L("请删除上面的文件、重新打开 MacBox 后再打开一次。", "Delete the file above, open MacBox again, then open \(it) again.")
        } else {
            L("请到正在运行的 MacBox 里再打开一次。", "Open \(it) again in the MacBox that’s running.")
        }
        return L("这次要打开的\(chinese)没有处理，", "Not opened: \(english). ") + advice
    }
}
