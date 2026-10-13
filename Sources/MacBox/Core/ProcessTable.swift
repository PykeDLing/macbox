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
    /// 系统代它启动的 XPC 服务都记在它头上；从程序坞、访达直接打开的 App 对自己负责
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let responsible = Private.responsiblePID else { return nil }
        let result = responsible(pid)
        return result > 0 ? result : nil
    }

    /// 可执行文件位于某目录下的进程（要遍历整个进程表，在后台执行）
    @concurrent
    static func pids(under prefix: String) async -> [pid_t] {
        allPIDs().filter { path(of: $0)?.hasPrefix(prefix) == true }
    }
}
