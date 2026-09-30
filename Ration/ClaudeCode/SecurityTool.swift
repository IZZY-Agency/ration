import Foundation

/// Runs macOS's `security` tool, the way Claude Code reads and writes its own
/// sign-in. Injected: tests use a fake and never touch the real Keychain.
protocol SecurityTool: Sendable {
    func run(_ arguments: [String], stdin: Data?) throws -> (status: Int32, output: Data)
}

struct SystemSecurityTool: SecurityTool {
    func run(_ arguments: [String], stdin: Data?) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
