import AppKit

// 启动器里的小程序（启动器见 MacBox 的 Launcher）。build.sh 把它编译好放进 MacBox.app，安装启动器时克隆过去。
//
// 以前这里是一个两行的脚本，只会告诉 MacBox“打开这个盒子”。启动器声明了应用能打开的链接和文件类型之后，
// 系统会先启动启动器，再把链接、文件作为一条系统事件发给它；脚本收不了事件，链接就悄悄丢了（实测）。
// 所以换成能收事件的程序，做的事还是那一件，多带一样东西：
//
// - 没收到东西（从聚焦、程序坞直接打开）：告诉 MacBox 打开盒子，退出。和脚本一样；
// - 收到了链接或文件：盒子里的应用已经在隔离中运行，就直接交给它；没有就先让 MacBox 打开盒子，
//   等它在隔离中启动好再交。交完退出。
//
// 由启动器自己交，而不是转给 MacBox 去交：访达把文件交给启动器时，一起给了这个文件的访问权，由它交出去，
// 这份权限才传得到应用手里（文件在「下载」「桌面」「文稿」里时，应用不用再弹窗问你）。
// 不常驻、没有界面、不联网、不读写文件；等不到应用（最多 waitLimit）也会退出。

/// 等应用在隔离中启动好，最多这么久。MacBox 没开时要先启动 MacBox、收拾上次的收尾，再启动应用
let waitLimit: TimeInterval = 30

let info = Bundle.main.infoDictionary ?? [:]
let boxID = info["MacBoxBoxID"] as? String ?? ""
/// 盒子里的 App（真实路径）。没有时只会打开盒子
let appPath = (info["MacBoxAppPath"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
/// 只有试用、测试用的 MacBox（MACBOX_DATA_ROOT）建的启动器才有：交给建它的那个 MacBox，
/// 而不是 macbox:// 的默认处理者（那是你平时用的 MacBox，不认识测试数据里的盒子）
let host = (info["MacBoxHost"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }

private typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
private let sandboxCheck = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check")
    .map { unsafeBitCast($0, to: SandboxCheck.self) }

/// 盒子里的应用正在隔离中运行、已经向系统报到的那个实例。
/// 没报到就交的话，系统会在隔离之外另开一个来接（实测），MacBox 的守卫会结束它，交的东西也就丢了。
/// 所以也不交给不在沙盒里的实例（有人从访达直接打开了它，守卫正要结束它）；接口不可用时不挑
func isolatedInstance() -> NSRunningApplication? {
    guard let appPath else { return nil }
    return NSWorkspace.shared.runningApplications.first { app in
        guard !app.isTerminated, app.isFinishedLaunching,
              app.bundleURL?.resolvingSymlinksInPath().path == appPath else { return false }
        return sandboxCheck.map { $0(app.processIdentifier, nil, 0) != 0 } ?? true
    }
}

/// 告诉 MacBox：open 打开这个盒子，undelivered 有东西没能交给应用（MacBox 给出说明）
func tellMacBox(_ action: String, then done: @escaping @Sendable () -> Void) {
    guard let url = URL(string: "macbox://\(action)/\(boxID)") else { return done() }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.promptsUserIfNeeded = false
    if let host {
        NSWorkspace.shared.open([url], withApplicationAt: host, configuration: configuration) { _, _ in done() }
    } else {
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in done() }
    }
}

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    /// 还没交出去的链接、文件。等应用的时候又收到的，一起交
    private var pending: [URL] = []
    private var finishedLaunching = false
    private var waiting: Timer?

    /// 冷启动时这一条早于 applicationDidFinishLaunching 到达
    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls
        if finishedLaunching, waiting == nil { deliver() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        // 不管出什么岔子都不留着
        DispatchQueue.main.asyncAfter(deadline: .now() + waitLimit + 30) { exit(1) }
        if pending.isEmpty || appPath == nil {
            tellMacBox("open") { exit(0) }
        } else {
            deliver()
        }
    }

    private func deliver() {
        if hand() { return }
        let deadline = Date().addingTimeInterval(waitLimit)
        tellMacBox("open") {}
        waiting = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.hand() {
                    self.waiting?.invalidate()
                } else if Date() > deadline {
                    self.waiting?.invalidate()
                    tellMacBox("undelivered") { exit(1) }
                }
            }
        }
    }

    /// 应用在隔离中准备好了就交给它，交完退出。返回 false：还没准备好
    private func hand() -> Bool {
        guard let appPath, isolatedInstance() != nil else { return false }
        let urls = pending
        pending = []
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: appPath, isDirectory: true),
                                configuration: configuration) { _, error in
            if error == nil { exit(0) }
            tellMacBox("undelivered") { exit(1) }
        }
        return true
    }
}

let delegate = LauncherDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
