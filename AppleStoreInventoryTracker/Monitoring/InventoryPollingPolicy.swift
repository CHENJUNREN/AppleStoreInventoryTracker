import Foundation

/// Successful, fresh batches drive activity; failures never mean that stock disappeared.
struct InventoryPollingPolicy {
    enum Phase { case regular, accelerated, observing }
    private(set) var phase: Phase = .regular
    private var phaseStarted: TimeInterval = 0
    private var emptyRounds = 0
    private var previouslyAvailable = false

    mutating func update(hasStock: Bool, succeeded: Bool, now: TimeInterval) {
        // Phase lifetimes still expire during errors, but errors cannot renew them.
        if phase == .accelerated && now - phaseStarted >= 600 {
            phase = .observing
            phaseStarted = now
            emptyRounds = 0
        } else if phase == .observing && now - phaseStarted >= 300 {
            phase = .regular
        }
        guard succeeded else { emptyRounds = 0; return }
        let newlyAvailable = hasStock && !previouslyAvailable
        previouslyAvailable = hasStock
        switch phase {
        case .regular:
            if newlyAvailable {
                phase = .accelerated
                phaseStarted = now
                emptyRounds = 0
            }
        case .accelerated:
            emptyRounds = hasStock ? 0 : emptyRounds + 1
            if emptyRounds >= 3 {
                phase = .observing
                phaseStarted = now
            }
        case .observing:
            if newlyAvailable {
                phase = .accelerated
                phaseStarted = now
                emptyRounds = 0
            }
        }
    }

    func interval(base: Int) -> Int {
        switch phase {
        case .regular: return base
        case .accelerated: return min(base, 15)
        case .observing: return min(base, 30)
        }
    }
}
