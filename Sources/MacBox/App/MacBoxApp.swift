import AppKit
import SwiftUI

@main
struct MacBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let store = BoxStore.shared
    private let virtualMac = VirtualMac.shared

    var body: some Scene {
        Window("MacBox", id: WindowID.library.rawValue) {
            MainView()
        }
        .environment(store)
        .environment(virtualMac)
        .defaultSize(width: 1120, height: 720)
        .commands { MacBoxCommands(store: store) }
        // 模型请求打开窗口（从聚焦打开虚拟 Mac 应用、⌘, 等）：在场景层处理，窗口全关着时也有效
        .onChange(of: store.windowRequest) { _, request in
            if let request { openWindow(id: request.window.rawValue) }
        }

        Window(Text(L("虚拟 Mac", "Virtual Mac")), id: WindowID.virtualMac.rawValue) {
            VirtualMacWindow()
        }
        .environment(store)
        .environment(virtualMac)
        .defaultSize(width: 1440, height: 940)
    }
}

private struct MacBoxCommands: Commands {
    let store: BoxStore
    @FocusedValue(\.importApps) private var importApps

    var body: some Commands {
        // 设置在主窗口侧边栏里，⌘, 直接切过去
        CommandGroup(replacing: .appSettings) {
            Button(L("设置…", "Settings…")) { store.show(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button(L("添加应用…", "Add App…")) { importApps?() }
                .keyboardShortcut("o")
                .disabled(importApps == nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 冷启动时 application(_:open:) 早于 didFinishLaunching 到达，所以在 will 阶段启动
    func applicationWillFinishLaunching(_ notification: Notification) {
        BoxStore.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 聚焦里的启动器通过 macbox://open/<id> 打开应用；
    /// 把 dmg 拖到程序坞的 MacBox 图标上、或「打开方式 › MacBox」则添加应用：
    /// 进度和结果只在「全部应用」里显示，窗口关着、停在别的页面时要先切过去，否则看起来什么也没发生
    func application(_ application: NSApplication, open urls: [URL]) {
        let store = BoxStore.shared
        for url in urls where !url.isFileURL { store.handle(url) }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            store.show(.allApps)
            Task { await store.importItems(files) }
        }
    }

    /// 退出前：请隔离中的应用退出并等它们收回设置、做完收尾，等进行中的维护和添加做完；虚拟 Mac 进入睡眠。
    /// 应用不肯退出、虚拟 Mac 睡不了时问用户，而不是到时间就强制结束（没存的内容会丢）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = BoxStore.shared
        let vm = VirtualMac.shared
        guard store.hasPendingWork || vm.isActive || vm.isInstalling else { return .terminateNow }
        if vm.isInstalling, !confirmCancellingSetup() { return .terminateCancel }
        Task {
            sender.reply(toApplicationShouldTerminate: await prepareToQuit(store: store, vm: vm))
        }
        return .terminateLater
    }

    /// 返回 false 表示用户取消了退出
    private func prepareToQuit(store: BoxStore, vm: VirtualMac) async -> Bool {
        while true {
            let refusing = await store.quitAll()
            if refusing.isEmpty { break }
            // 不抢前台：你可能正在应用的存储面板里输入文件名。在程序坞里提醒，等你切回 MacBox 再问；
            // 等的时候应用自己退出了就不用问了
            await waitUntilActive { !refusing.contains(where: \.isRunning) }
            guard refusing.contains(where: \.isRunning) else { continue }
            guard confirmForceQuit(refusing.filter(\.isRunning)) else {
                store.cancelQuit()
                return false
            }
            for box in refusing { await box.forceQuit() }
        }
        // 应用都退出了、MacBox 确定要退出了才中断虚拟 Mac 的设置：在上面取消退出的话，设置照常继续，
        // 不会白白丢掉已经下载、安装了一半的 macOS
        if vm.isInstalling { await vm.cancelSetupAndWait() }
        if !(await vm.prepareForTermination()) {
            guard confirmForceStop(vm) else {
                store.cancelQuit()
                return false
            }
            await vm.forceStop()
        }
        return true
    }

    /// 虚拟 Mac 正在设置：退出会中断设置，先问
    private func confirmCancellingSetup() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("要取消虚拟 Mac 的设置并退出吗？", "Cancel the Virtual Mac setup and quit?")
        alert.informativeText = L("设置会中断，下次需要重新开始。", "Setup will stop, and you’ll need to start it again next time.")
        alert.addButton(withTitle: L("继续设置", "Continue Setup"))
        let quit = alert.addButton(withTitle: L("取消设置并退出", "Cancel Setup and Quit"))
        quit.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// MacBox 不在前台时，在程序坞里提醒，等到它被切到前台（或者 done 成立）为止
    private func waitUntilActive(or done: () -> Bool) async {
        guard let app = NSApp, !app.isActive else { return }
        let request = app.requestUserAttention(.criticalRequest)
        defer { app.cancelUserAttentionRequest(request) }
        while !app.isActive, !done() {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 有应用不肯退出：强制退出它们再退出 MacBox，还是取消退出。默认按钮是“取消”：没存的内容会丢。
    /// 只在 MacBox 已经在前台时调用（见 waitUntilActive），不去抢前台
    private func confirmForceQuit(_ boxes: [Box]) -> Bool {
        let names = boxes.map(\.config.name)
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? L("「\(names[0])」没有退出", "“\(names[0])” didn’t quit")
            : L("\(names.count) 个应用没有退出", "\(names.count) apps didn’t quit")
        alert.informativeText = L("\(BoxStore.chineseList(names))可能在等你存储文稿，或者没有响应。可以切过去处理后再退出 MacBox；强制退出会丢失没有存储的内容。",
                                  "\(BoxStore.englishList(names)) may be waiting for you to save changes, or may not be responding. You can switch to \(names.count == 1 ? "it" : "them") and quit MacBox again later. If you force \(names.count == 1 ? "it" : "them") to quit, any unsaved changes will be lost.")
        alert.addButton(withTitle: L("取消", "Cancel"))
        let force = alert.addButton(withTitle: L("强制退出并退出 MacBox", "Force Quit and Quit MacBox"))
        force.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 虚拟 Mac 睡不了：强制关机再退出，还是取消退出
    private func confirmForceStop(_ vm: VirtualMac) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("虚拟 Mac 无法进入睡眠", "The Virtual Mac couldn’t go to sleep")
        alert.informativeText = [vm.lastError, L("强制关机会丢失虚拟 Mac 里没有存储的内容。",
                                                 "If you force it to shut down, any unsaved changes in the Virtual Mac will be lost.")]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: L("取消", "Cancel"))
        let force = alert.addButton(withTitle: L("强制关机并退出 MacBox", "Force Shut Down and Quit MacBox"))
        force.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
