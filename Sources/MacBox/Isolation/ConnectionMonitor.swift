import Darwin
import Foundation

/// 盒子里的进程连了哪些服务器（运行报告用）。
///
/// 系统没有给普通程序的连接事件，只能定时看一眼：用 nettop 取一次会话进程此刻的连接。
/// 不读进程的文件描述符（lsof 的做法）：URLSession、Network.framework 的连接在用户态网络栈里，
/// 进程的文件描述符里没有，实测 lsof 一个也看不到；nettop 经由内核的网络统计看得到。
/// 一直开着的 nettop 很费 CPU（实测约 1.3 个核），取一次只要几十毫秒，所以每次都重新启动。
/// 只是看一眼：两次之间开始又结束的短连接会漏掉
nonisolated enum ConnectionMonitor {
    /// 这些进程此刻的连接（监听、还没连上对方的不算）。nettop 启动不了时为空
    @concurrent
    static func connections(of pids: [pid_t]) async -> [ServerContact] {
        guard !pids.isEmpty else { return [] }
        var options = ChildProcess.Options()
        options.output = .pipe
        guard let process = try? ChildProcess.spawn("/usr/bin/nettop", ["-n", "-L", "1", "-J", "state"] + pids.flatMap { ["-p", "\($0)"] },
                                                     options: options) else { return [] }
        let output = await process.standardOutput.collect()
        _ = await process.waitForExit()
        // nettop 只给进程名的前 15 个字符（“com.apple.WebKi”），按 pid 换成完整的程序名
        return parse(String(decoding: output, as: UTF8.self)) { ProcessTable.path(of: $0).map { ($0 as NSString).lastPathComponent } }
    }

    /// 解析 nettop -L 的 CSV：进程一行（“名字.pid”，名字最多 15 个字符），下面跟着它的连接
    /// （“tcp4 192.168.1.2:61189<->141.95.207.211:443”，IPv6 的端口用点隔开：“tcp6 fe80::1.5353<->ff02::fb.5353”；
    /// HTTP/3 是 “quic4 …”，WebKit、URLSession 访问支持它的网站时就用它）。
    /// 进程、连接在表头里没有名字的那一列：默认在 time 后面，用 -J 选列时没有 time，就是第一列
    /// - name：按 pid 取进程的完整名字；取不到时用 nettop 给的
    static func parse(_ csv: String, name: (pid_t) -> String? = { _ in nil }) -> [ServerContact] {
        var contacts: [ServerContact] = []
        var process: String?
        let lines = csv.split(separator: "\n")
        guard let header = lines.first,
              let column = header.split(separator: ",", omittingEmptySubsequences: false).firstIndex(where: \.isEmpty) else { return [] }
        for line in lines.dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count > column else { continue }
            let item = columns[column]
            // 连接行都带 “<->”；其余是进程行：“com.apple.WebKi.4321”，名字可能带空格（“Claude Helper.34970”，
            // 截到 15 个字符时还会留下结尾的空格：“Microsoft Edge .785”）
            guard let arrow = item.range(of: "<->") else {
                guard let dot = item.lastIndex(of: ".") else {
                    process = String(item)
                    continue
                }
                process = pid_t(item[item.index(after: dot)...]).flatMap(name)
                    ?? String(item[..<dot]).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let space = item.firstIndex(of: " "), space < arrow.lowerBound else { continue }
            let kind = item[..<space]
            guard let transport = ["tcp", "udp", "quic"].first(where: { kind.hasPrefix($0) }) else { continue }
            let remote = item[arrow.upperBound...]
            let separator: Character = kind.hasSuffix("6") ? "." : ":"
            guard let split = remote.lastIndex(of: separator) else { continue }
            let address = String(remote[..<split]), port = Int(remote[remote.index(after: split)...])
            guard let port, port > 0, address != "*", !address.isEmpty else { continue } // 监听、没连上
            contacts.append(ServerContact(address: address, port: port, transport: transport, process: process))
        }
        return contacts
    }

    /// 反向解析 IP 地址的名字（PTR 记录）。很多地址没有，就是 nil。
    /// getnameinfo 会阻塞（最长要等 DNS 超时），放到自己的队列上，不占 Swift 并发的线程
    static func reverseName(_ address: String) async -> String? {
        await withCheckedContinuation { continuation in
            resolver.async { continuation.resume(returning: lookUp(address)) }
        }
    }

    private static let resolver = DispatchQueue(label: "MacBox.ConnectionMonitor.resolve", attributes: .concurrent)

    private static func lookUp(_ address: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &info) == 0, let info else { return nil }
        defer { freeaddrinfo(info) }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) == 0 else {
            return nil
        }
        let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
