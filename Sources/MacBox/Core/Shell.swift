import Foundation

/// 运行命令行工具（hdiutil、security、codesign…）并收集输出
nonisolated enum Shell {
    struct Result: Sendable {
        let status: Int32
        let outputData: Data
        let errorData: Data
        var output: String { String(decoding: outputData, as: UTF8.self) }
        var error: String { String(decoding: errorData, as: UTF8.self) }
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 运行并返回结果；退出码非 0 时抛错
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], input: String? = nil) async throws -> Result {
        let result = try await execute(executable, arguments, input: input)
        guard result.status == 0 else {
            let message = result.error.isEmpty ? result.output : result.error
            throw MacBoxError("\((executable as NSString).lastPathComponent) 失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }

    /// 运行并返回结果，不检查退出码。任务被取消时结束子进程并抛出 CancellationError
    static func execute(_ executable: String, _ arguments: [String], input: String? = nil) async throws -> Result {
        var options = ChildProcess.Options()
        options.input = input.map { .data(Data($0.utf8)) } ?? .null
        options.output = .pipe
        options.error = .pipe
        let process = try ChildProcess.spawn(executable, arguments, options: options)
        return try await withTaskCancellationHandler {
            // 两路输出同时读：都是挂起等待，不占线程
            async let output = process.standardOutput.collect()
            async let error = process.standardError.collect()
            let (out, err) = await (output, error)
            let status = await process.waitForExit()
            try Task.checkCancellation()
            return Result(status: status, outputData: out, errorData: err)
        } onCancel: {
            process.signal(SIGTERM)
        }
    }
}
