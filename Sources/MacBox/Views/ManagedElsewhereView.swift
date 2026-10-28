import AppKit
import SwiftUI

/// 另一个 MacBox 正在管理这些盒子（见 EngineLock）：这里不显示、也不碰任何盒子，只说明情况。
/// 显示空的应用列表会让人以为盒子都没了
struct ManagedElsewhereView: View {
    @Environment(BoxStore.self) private var store

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(L("另一个 MacBox 正在管理这些盒子", "Another MacBox Is Managing These Boxes"))
                .font(.title2.weight(.semibold))
            Text(L("同一时间只能由一个 MacBox 管理盒子：两个一起运行时，会互相结束对方打开的应用、收回对方借出的设置。请使用正在运行的那个。",
                   "Only one MacBox can manage the boxes at a time. If two ran together, each would quit the apps the other opened and take back the settings the other lent out. Use the one that’s already running."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if let holder {
                Text(Self.describe(holder))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button(L("退出", "Quit")) { NSApp.terminate(nil) }
                if let other = runningOther {
                    Button(L("切换过去", "Switch to It")) { switchTo(other) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var holder: EngineLock.Holder? {
        if case .otherProcess(let holder) = store.ownership { holder } else { nil }
    }

    /// 拿着锁的是一个 App（可以切过去）时，它的进程
    private var runningOther: NSRunningApplication? {
        guard let holder, holder.appURL != nil, let app = NSRunningApplication(processIdentifier: holder.pid),
              !app.isTerminated else { return nil }
        return app
    }

    /// 切到正在管理盒子的那个，这个退出：留着也什么都做不了
    private func switchTo(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate()
        NSApp.terminate(nil)
    }

    nonisolated static func describe(_ holder: EngineLock.Holder) -> String {
        let path = (holder.path as NSString).abbreviatingWithTildeInPath
        if let version = holder.version {
            return L("正在运行的是：\(path)（版本 \(version)）", "The one running: \(path) (version \(version))")
        }
        return L("正在运行的是：\(path)", "The one running: \(path)")
    }
}
