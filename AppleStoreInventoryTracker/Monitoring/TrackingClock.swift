import Foundation

@MainActor
protocol TrackingClock {
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
struct SystemTrackingClock: TrackingClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
