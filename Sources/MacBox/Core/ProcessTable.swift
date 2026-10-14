import Darwin
import Foundation

/// 读取系统进程表（只读查询；启动进程见 ChildProcess）
nonisolated enum ProcessTable {
    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0)))).filter { $0 > 0 }
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    /// 进程是否处于沙盒中（任何沙盒，包括 App 自带的苹果沙盒）。接口不可用时视为在沙盒中，守卫不误杀
    static func isSandboxed(_ pid: pid_t) -> Bool {
        guard let check = Private.sandboxCheck else { return true }
        return check(pid, nil, 0) != 0
    }

    /// 进程的负责进程：MacBox 以 disclaim 方式启动的 App 对自己负责，它派生的子进程、
    /// 系统代它启动的 XPC 服务都记在它头上；从程序坞、访达直接打开的 App 对自己负责。
    /// 实测两处例外，不能只靠它判断进程属于哪个会话：
    /// - 会话里的程序启动另一个 App 包里的可执行文件（比如 sh 启动盒子里的 App），新进程对自己负责；
    /// - 会话主进程退出后，留下的进程改为对自己负责，它们之后派生的进程也记在它们自己头上
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsible = Private.responsiblePID else { return nil }
        let result = responsible(pid)
        return result > 0 ? result : nil
    }

    struct Lineage: Sendable {
        /// 父进程（原来的父进程退出后是 launchd，即 1）
        let parent: pid_t
        /// 进程组：子进程默认继承，父进程退出后也不变
        let group: pid_t
        /// 已退出、等待父进程回收
        let isZombie: Bool
    }

    /// 父进程和进程组。查不到（进程已不存在）时为 nil
    static func lineage(of pid: pid_t) -> Lineage? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Lineage(parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid), isZombie: info.pbi_status == SZOMB)
    }

    /// 进程组里的进程（含僵尸进程）。组里没有进程时为空：进程组号在组里还有进程时不会被新进程占用
    static func pids(inGroup group: pid_t) -> [pid_t] {
        guard group > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: 256)
        while true {
            let count = proc_listpgrppids(group, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return [] }
            if Int(count) < pids.count { return Array(pids.prefix(Int(count))).filter { $0 > 0 } }
            pids = [pid_t](repeating: 0, count: pids.count * 4) // 装满了：可能还有，放大再取
        }
    }

    /// 启动参数（KERN_PROCARGS2；只能读同一用户的进程）。第一个是 argv[0]
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // 布局：argc（int）、可执行文件路径、若干 \0 填充、argc 个以 \0 结尾的参数、环境变量…
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // 可执行文件路径
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// 可执行文件是常见的脚本解释器（只看名字，不碰文件系统）
    static func isInterpreter(_ executable: String) -> Bool {
        let name = (executable as NSString).lastPathComponent.lowercased()
        return shells.contains(name) || ["osascript", "tclsh", "wish"].contains(name)
            || ["python", "perl", "ruby", "node", "php"].contains { name.hasPrefix($0) }
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"]

    /// 解释器运行的脚本：`/bin/bash /盒子/…/MacOS/启动脚本`、`python3 -u 脚本`。
    /// 主程序是脚本的 App 运行时，进程的可执行文件是解释器，脚本路径只出现在参数里
    /// （内核执行 #! 脚本时把参数改成“解释器 [#! 行的参数] 脚本路径 原参数…”）。
    /// 只认常见的脚本解释器、跳过选项后的第一个参数；`sh -c 命令`、`python3 -c 代码` 这类没有脚本文件。
    /// 返回参数原样（绝对路径），不解析符号链接：解析要逐级访问路径，路径在没响应的网络卷上时会卡住，
    /// 由调用方决定要不要、在哪里解析
    static func scriptArgument(of pid: pid_t, executable: String) -> String? {
        guard isInterpreter(executable), let arguments = arguments(of: pid) else { return nil }
        let isShell = shells.contains((executable as NSString).lastPathComponent.lowercased())
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("-") {
                let inline = isShell ? !argument.hasPrefix("--") && argument.contains("c")
                                     : ["-c", "-e", "-E", "-m", "-r"].contains(argument)
                if inline { return nil }
                continue
            }
            return argument.hasPrefix("/") ? argument : nil
        }
        return nil
    }

    /// 直接子进程（含僵尸进程）
    static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: 64)
        while true {
            let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return [] }
            if Int(count) < pids.count { return Array(pids.prefix(Int(count))).filter { $0 > 0 } }
            pids = [pid_t](repeating: 0, count: pids.count * 4) // 装满了：可能还有，放大再取
        }
    }

    /// 可执行文件位于某目录下的进程（要遍历整个进程表）
    static func processes(under prefix: String) -> [pid_t] {
        allPIDs().filter { path(of: $0)?.hasPrefix(prefix) == true }
    }

    /// 同上，在后台执行
    @concurrent
    static func pids(under prefix: String) async -> [pid_t] {
        processes(under: prefix)
    }
}
