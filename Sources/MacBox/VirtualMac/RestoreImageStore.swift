import Foundation
import Synchronization
import Virtualization

/// 管理 macOS 恢复镜像（IPSW）：查询、下载、缓存，多个沙盒共用
enum RestoreImageStore {
    static func cachedImages() -> [URL] {
        FileOps.contents(of: AppPaths.restoreImages).filter { $0.pathExtension == "ipsw" }
    }

    // 框架没有提供 async 版本。回调交出的是新建的镜像对象，回调之后框架不再使用它，
    // 所以可以安全地把它转交给等待方（nonisolated(unsafe) 只用于这次转交）

    static func load(_ url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                nonisolated(unsafe) let result = result
                continuation.resume(with: result)
            }
        }
    }

    static func fetchLatestSupported() async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                nonisolated(unsafe) let result = result
                continuation.resume(with: result)
            }
        }
    }

    /// 获取适用于本机的最新 macOS 镜像，已缓存则直接复用。任务取消时停止下载。
    /// onStatus 的调用全部在返回前完成，不会有迟到的进度覆盖之后的状态
    static func obtainLatest(onStatus: (String, Double?) -> Void) async throws -> URL {
        onStatus(L("正在查询适用于这台 Mac 的最新 macOS…", "Checking for the latest macOS for this Mac…"), nil)
        let latest = try await fetchLatestSupported()
        try Task.checkCancellation()
        let version = latest.operatingSystemVersion.displayString
        let destination = try AppPaths.ensure(AppPaths.restoreImages)
            .appending(path: "macOS-\(version)-\(latest.buildVersion).ipsw")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let (updates, continuation) = AsyncStream.makeStream(of: FileDownloader.Progress.self,
                                                             bufferingPolicy: .bufferingNewest(1))
        let downloader = FileDownloader(source: latest.url, destination: destination, progress: continuation)
        async let download: Void = downloader.run()
        for await update in updates {
            let progress = update.total > 0 ? Double(update.written) / Double(update.total) : nil
            let written = FileOps.formatBytes(update.written), total = FileOps.formatBytes(update.total)
            onStatus(L("正在下载 macOS \(version)（\(written) / \(total)）",
                       "Downloading macOS \(version) (\(written) of \(total))…"), progress)
        }
        try await download
        return destination
    }
}

/// 带进度的大文件下载器（IPSW 通常 15GB 以上），支持任务取消
nonisolated final class FileDownloader: NSObject, URLSessionDownloadDelegate, Sendable {
    struct Progress: Sendable {
        let written: Int64
        let total: Int64
    }

    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var finishError: Error?
        var lastReport = Date.distantPast
    }

    private let source: URL
    private let destination: URL
    private let progress: AsyncStream<Progress>.Continuation
    private let state = Mutex(State())

    /// 下载结束（无论成败）时 progress 序列随之结束
    init(source: URL, destination: URL, progress: AsyncStream<Progress>.Continuation) {
        self.source = source
        self.destination = destination
        self.progress = progress
    }

    @concurrent
    func run() async throws {
        defer { progress.finish() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
                let task = session.downloadTask(with: source)
                let cancelled = state.withLock { state in
                    state.continuation = continuation
                    state.task = task
                    return state.cancelled
                }
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            let task = state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let report = state.withLock { state in
            guard now.timeIntervalSince(state.lastReport) > 0.25 else { return false }
            state.lastReport = now
            return true
        }
        if report { progress.yield(Progress(written: totalBytesWritten, total: totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw MacBoxError(L("下载失败：服务器返回 \(http.statusCode)",
                                    "Download failed: the server returned \(http.statusCode)"))
            }
            // 先移到 .partial 再改名，避免留下不完整的 .ipsw
            let partial = destination.appendingPathExtension("partial")
            try FileOps.removeIfExists(partial)
            try FileManager.default.moveItem(at: location, to: partial)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            state.withLock { $0.finishError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let (continuation, finishError) = state.withLock { state in
            defer { state.continuation = nil }
            return (state.continuation, state.finishError)
        }
        if let error = error ?? finishError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
