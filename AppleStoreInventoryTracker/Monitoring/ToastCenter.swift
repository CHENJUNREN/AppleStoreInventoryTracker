import AppKit
import Observation

@MainActor @Observable
final class ToastCenter {
    enum Kind { case success, information, error }
    struct Message: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
    }
    private(set) var message: Message?
    private(set) var hosts: [UUID] = []
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func show(_ text: String, kind: Kind = .success, duration: Duration? = nil) {
        dismissal?.cancel()
        let next = Message(text: text, kind: kind)
        message = next
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: duration ?? (kind == .error ? .seconds(5) : .seconds(3))) }
            catch { return }
            guard self?.message?.id == next.id else { return }
            self?.message = nil
        }
        if let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func dismiss() { dismissal?.cancel(); dismissal = nil; message = nil }
    func register(_ id: UUID) { hosts.removeAll { $0 == id }; hosts.append(id) }
    func unregister(_ id: UUID) { hosts.removeAll { $0 == id } }
}
