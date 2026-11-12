import Darwin
import Foundation

/// 应用留在系统共用的临时、缓存目录里的东西，由 MacBox 代为清理。
///
/// /private/tmp 和 /private/var/folders（每个用户的临时目录 …/T、缓存目录 …/C 都在里面）所有程序共用，很多系统框架
/// 依赖它们，沙盒不能不让写。盒子的 TMPDIR 指向盒子里，但 NSTemporaryDirectory() 不看它，Metal 的着色器缓存、
/// 写死 /tmp 的程序（boost 的共享内存）也不看。两种办法各管一头：
/// - 运行期间新建的：沙盒放行，但每新建一项都在系统日志里记一笔（见 SandboxProfile、ViolationMonitor）。
///   所有进程退出后，临时目录里记下的那些还在的就删掉（见 remove）。缓存目录里的不删：下次启动还用得上
/// - 系统按 App 的标识符起名的文件夹（…/C/<标识符>、…/T/<标识符>）：删除盒子、清除数据时按名字删（见 removeNamedFolders）
///
/// 系统日志会漏记（见 ViolationMonitor），所以这是尽力而为：没记到的留在原处，和以前一样等系统自己清理
nonisolated enum SharedTemporary {
    /// 沙盒规则里新建时记一笔的范围（真实路径）
    static let reportedRoots = ["/private/tmp", "/private/var/folders"]

    /// 这个用户的临时目录、缓存目录（真实路径，带结尾的 /）。MacBox 自己不在沙盒里，问到的就是系统给这个用户的那两个
    static let userTemporary = userDirectory(_CS_DARWIN_USER_TEMP_DIR)
    static let userCache = userDirectory(_CS_DARWIN_USER_CACHE_DIR)

    /// 应用退出后清理的范围（真实路径，带结尾的 /）：所有用户共用的 /private/tmp 和这个用户的临时目录
    static var cleanedRoots: [String] { ["/private/tmp/"] + [userTemporary].compactMap { $0 } }

    private static func userDirectory(_ name: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let length = buffer.withUnsafeMutableBytes { confstr(name, $0.baseAddress, $0.count) } // 含结尾的 0
        guard length > 1, length <= buffer.count else { return nil }
        let path = FileOps.realPath(URL(fileURLWithPath: String(decoding: buffer.prefix(length - 1), as: UTF8.self), isDirectory: true))
        return path.hasPrefix("/private/var/folders/") ? path + "/" : nil
    }

    /// 清理的结果，存进运行报告。字段只增不改
    struct Cleanup: Codable, Hashable, Sendable {
        /// 删掉了多少个文件（链接、套接字也算，文件夹不算）
        var removed = 0
        /// 删掉的文件原来占的空间
        var bytes: Int64 = 0
        /// 删掉的东西在哪几处（临时目录里的顶层项目，见 display），最多 maxPlaces 处
        var places: [String] = []
        /// 应用新建、却没能删掉的几处（文件夹里还有别的东西、没有权限），最多 maxPlaces 处
        var remaining: [String] = []

        static let maxPlaces = 30
        var isEmpty: Bool { removed == 0 && places.isEmpty && remaining.isEmpty }
    }

    /// 运行期间记下的、应用在临时目录里新建的路径。只在会话所在的线程上用（见 IsolatedSession.run）
    final class Created {
        private(set) var paths: [String] = []
        private var seen: Set<String> = []
        /// 记多了说明应用在大量建临时文件，再记下去只是占内存；多出来的不清理
        static let limit = 20000

        /// 记下一条新建；不在清理范围里的不管（缓存目录里的不清理）
        func note(_ path: String, roots: [String] = SharedTemporary.cleanedRoots) {
            guard paths.count < Self.limit, roots.contains(where: { path.hasPrefix($0) }), seen.insert(path).inserted else { return }
            paths.append(path)
        }
    }

    /// 删掉应用在临时目录里新建、现在还在的东西。所有进程都退出之后调用。
    ///
    /// 路径来自系统日志，照着它在沙盒外删东西，所以每一项都要过这几关，过不了的不动：
    /// - 在清理范围里，并且不在 MacBox 自己的数据目录里（测试时盒子就在临时目录下）；
    /// - 上级目录的真实路径就是它本身：日志里记的是真实路径，现在多出了符号链接，说明有一级被换成了链接
    ///   （先建文件夹和文件、再把文件夹换成指向「文稿」的链接，照着删就删到了「文稿」里的同名文件）；
    /// - 是这个用户的，并且是这次运行开始之后才建的（since，留 2 秒余量）：同一个路径上原来就有的不是它建的。
    /// 文件夹只在空了的时候删（rmdir）：里面还有东西，可能是别的程序放的（/tmp/boost_interprocess 这样的名字好几个程序共用），
    /// 也可能是日志漏记的，都留着、记进 remaining
    @concurrent
    static func remove(_ created: [String], since: Date, roots: [String] = cleanedRoots,
                       protecting: [String] = [FileOps.realPath(AppPaths.root) + "/"]) async -> Cleanup {
        var cleanup = Cleanup()
        var places: [String] = [], remaining: [String] = []
        func add(_ place: String, to list: inout [String]) {
            if !list.contains(place), list.count < Cleanup.maxPlaces { list.append(place) }
        }
        let earliest = since.timeIntervalSince1970 - 2
        let user = getuid()
        // 深的在前：先删文件夹里面的，文件夹才空得出来
        let ordered = created.sorted { ($0.utf8.count, $0) > ($1.utf8.count, $1) }
        for path in ordered {
            guard let root = roots.first(where: { path.hasPrefix($0) }), path.count > root.count, !path.hasSuffix("/"),
                  !path.contains("/../"), !path.contains("//"), !path.contains("\0"),
                  !protecting.contains(where: { path.hasPrefix($0) }) else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            guard let resolved = realpath(parent, nil) else { continue } // 上级已经不在了
            let real = String(cString: resolved)
            free(resolved)
            var info = stat()
            guard real == parent, lstat(path, &info) == 0, info.st_uid == user,
                  TimeInterval(info.st_birthtimespec.tv_sec) >= earliest else { continue }
            let place = display(path, root: root)
            if info.st_mode & S_IFMT == S_IFDIR {
                if rmdir(path) != 0 { add(place, to: &remaining) }
            } else if unlink(path) == 0 {
                cleanup.removed += 1
                if info.st_mode & S_IFMT == S_IFREG { cleanup.bytes += Int64(info.st_blocks) * 512 }
                add(place, to: &places)
            } else {
                add(place, to: &remaining)
            }
        }
        cleanup.places = places
        cleanup.remaining = remaining
        return cleanup
    }

    /// 报告里显示的位置：清理范围里的顶层项目。/private/tmp 里的原样；这个用户的临时目录路径里有一串随机的名字，
    /// 没有信息量，写成 /var/folders/…/T/<名字>
    static func display(_ path: String, root: String) -> String {
        let top = path.dropFirst(root.count).split(separator: "/").first.map(String.init) ?? ""
        return (root == "/private/tmp/" ? root : "/var/folders/…/T/") + top
    }

    /// 删掉系统按标识符起名、属于这个盒子的文件夹：…/C/<标识符>（Metal 的着色器缓存等）、…/T/<标识符>。
    /// 删除盒子、清除数据时调用，应用不在运行。按名字认，和偏好设置的借出范围同一套规矩：
    /// 名字在这个盒子的前缀之内（com.x.app、com.x.app.helper.GPU），并且不在别的盒子的前缀之内（others）、
    /// 不在本机装着的 App 的标识符之内（installed，包括同一个 App 的本机版本：那是它们共用的，本机的那份可能正在运行）。
    /// 返回删掉了几个
    @concurrent @discardableResult
    static func removeNamedFolders(prefixes: [String], others: [[String]], installed: Set<String>,
                                   in roots: [String] = [userCache, userTemporary].compactMap { $0 }) async -> Int {
        var removed = 0
        for root in roots {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                guard PreferenceLease.isSingleName(name), PreferenceLease.domain(name, isCoveredBy: prefixes),
                      !others.contains(where: { PreferenceLease.domain(name, isCoveredBy: $0) }),
                      !PreferenceLease.domain(name, isCoveredBy: Array(installed)) else { continue }
                let path = root + name
                var info = stat()
                // 只删真的文件夹：换成了链接的不跟过去
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
                if (try? FileOps.removeTree(URL(fileURLWithPath: path, isDirectory: true))) != nil { removed += 1 }
            }
        }
        return removed
    }
}
