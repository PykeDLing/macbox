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
        // 模型请求打开窗口（启动台打开虚拟 Mac 应用、⌘, 等）：在场景层处理，窗口全关着时也有效
        .onChange(of: store.windowRequest) { _, request in
            if let request { openWindow(id: request.window.rawValue) }
        }

        Window("虚拟 Mac", id: WindowID.virtualMac.rawValue) {
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
            Button("设置…") { store.show(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("添加应用…") { importApps?() }
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

    /// 启动台里的启动器通过 macbox://open/<id> 打开应用；
    /// 把 dmg 拖到程序坞的 MacBox 图标上、或「打开方式 › MacBox」则添加应用
    func application(_ application: NSApplication, open urls: [URL]) {
        let store = BoxStore.shared
        for url in urls where !url.isFileURL { store.handle(url) }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { Task { await store.importItems(files) } }
    }

    /// 退出前：隔离中的应用正常退出并收回设置；虚拟 Mac 进入睡眠
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = BoxStore.shared
        let vm = VirtualMac.shared
        guard !store.liveBoxes.isEmpty || vm.virtualMachine != nil else { return .terminateNow }
        Task {
            await store.quitAll()
            await vm.sleep()
            if vm.virtualMachine != nil { await vm.forceStop() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
