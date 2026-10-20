import Foundation

@MainActor
protocol TrackingClock {
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
struct SystemTrackingClock: TrackingClock {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    // Unlike uptime, this monotonic clock includes system sleep. The existing
    // one-second countdown loop therefore rechecks overdue work on wake, without
    // restarting the run, bypassing cooldowns, or replaying missed requests.
    var now: TimeInterval {
        let elapsed = origin.duration(to: clock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    func sleep(seconds: TimeInterval) async throws {
        try await clock.sleep(for: .seconds(seconds))
    }
}
