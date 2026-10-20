import Foundation
import Darwin

/// Runs the real activity in a disposable child, never terminates the user's app.
@main
struct MonitoringActivityProcessTests {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.contains("--child") {
            let activity = MonitoringActivity()
            activity.begin()
            FileHandle.standardOutput.write(Data("ready\n".utf8))
            withExtendedLifetime(activity) { _ = readLine() }
            return
        }

        for signal in [SIGTERM, SIGKILL] {
            let child = Process()
            let output = Pipe()
            let input = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--child"]
            child.standardOutput = output
            child.standardInput = input
            try child.run()
            defer {
                if child.isRunning {
                    kill(child.processIdentifier, SIGKILL)
                    child.waitUntilExit()
                }
                try? input.fileHandleForWriting.close()
            }
            let ready = output.fileHandleForReading.readData(ofLength: 6)
            precondition(ready == Data("ready\n".utf8), "Child failed to create activity")
            let pid = child.processIdentifier
            try waitForAssertion(pid: pid, present: true)
            precondition(kill(pid, signal) == 0, "Failed to terminate test child")
            child.waitUntilExit()
            precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == signal,
                         "Child must exit without running normal cleanup")
            try waitForAssertion(pid: pid, present: false)
            print("PASS: signal \(signal) termination leaves no process-owned power assertion")
        }
    }

    private static func waitForAssertion(pid: Int32, present: Bool) throws {
        for _ in 0..<30 {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Cannot inspect power assertions")
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .filter { $0.contains("pid \(pid)(") }
            if present {
                if lines.contains(where: { $0.contains("PreventUserIdleSystemSleep") }) { return }
            } else if lines.isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        fatalError(present ? "Missing active sleep assertion" : "Power assertion survived process termination")
    }
}
