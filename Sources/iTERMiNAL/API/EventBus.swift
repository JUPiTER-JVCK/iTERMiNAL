import Foundation

/// One thing that happened in the app, published to API subscribers as
/// `{"event":"session.exited","data":{…}}`.
struct APIEvent {
    let name: String
    let data: [String: Any]

    init(_ name: String, _ data: [String: Any] = [:]) {
        self.name = name
        self.data = data
    }

    var payload: [String: Any] {
        ["event": name, "data": data]
    }
}

/// Fan-out for API event subscriptions — the half of the plugin story that
/// request/response couldn't cover.
///
/// Subscribers are API connections that asked for events with `subscribe`.
/// Everything runs on the main queue, matching the rest of the app state.
final class EventBus {
    static let shared = EventBus()

    /// Event names a subscriber can ask for. `*` means everything.
    static let allEvents = [
        "session.started", "session.exited", "session.directory",
        "session.title", "session.activity", "session.link",
        "tab.created", "tab.closed", "tab.selected",
        "workspace.created", "pane.split", "pane.closed",
        "browser.navigated", "browser.tab.created", "browser.tab.closed",
        "dock.session.created", "dock.session.closed",
    ]

    private var subscribers: [UUID: (names: Set<String>, deliver: (APIEvent) -> Void)] = [:]

    private init() {}

    func subscribe(id: UUID, to names: Set<String>, deliver: @escaping (APIEvent) -> Void) {
        onMain { self.subscribers[id] = (names, deliver) }
    }

    func unsubscribe(id: UUID) {
        onMain { self.subscribers.removeValue(forKey: id) }
    }

    func publish(_ event: APIEvent) {
        onMain {
            // Cheap no-op when nobody is listening — activity fires often.
            guard !self.subscribers.isEmpty else { return }
            for (_, subscriber) in self.subscribers
            where subscriber.names.contains("*") || subscriber.names.contains(event.name) {
                subscriber.deliver(event)
            }
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
