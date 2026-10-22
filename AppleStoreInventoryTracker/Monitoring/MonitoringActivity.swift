import Foundation

@MainActor
protocol MonitoringActivityManaging {
    func begin()
    func end()
}

/// Prevent idle system sleep only while the user has explicitly started monitoring.
/// Display sleep and screen locking remain available.
/// The assertion belongs to this process: macOS reclaims it when the process dies,
/// including SIGKILL, where neither end() nor deinit can execute.
/// Verified by scripts/test-power.sh; no crash/signal cleanup handler is required.
@MainActor
final class MonitoringActivity: MonitoringActivityManaging {
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "正在监控 Apple Store 到店取货库存"
        )
    }

    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
