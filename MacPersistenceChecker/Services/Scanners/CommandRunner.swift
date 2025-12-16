import Foundation

/// Utility per eseguire comandi con timeout
enum CommandRunner {
    /// Run a command with timeout (default 5 seconds)
    static func run(_ path: String, arguments: [String] = [], timeout: TimeInterval = 5.0) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var hasResumed = false
            let lock = NSLock()

            // Timeout handler
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                if !hasResumed {
                    hasResumed = true
                    if process.isRunning {
                        process.terminate()
                    }
                    lock.unlock()
                    continuation.resume(returning: "")
                } else {
                    lock.unlock()
                }
            }

            do {
                try process.run()
                process.waitUntilExit()

                lock.lock()
                if !hasResumed {
                    hasResumed = true
                    lock.unlock()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else {
                    lock.unlock()
                }
            } catch {
                lock.lock()
                if !hasResumed {
                    hasResumed = true
                    lock.unlock()
                    continuation.resume(returning: "")
                } else {
                    lock.unlock()
                }
            }
        }
    }
}
