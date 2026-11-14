import AppKit
import EventKit
import Observation
import PerchCore

struct EventRow: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarName: String
}

/// Today's events, read-only. Nothing here calls save or remove on the event store.
@Observable
final class CalendarService {
    var events: [EventRow] = []
    var status = EKEventStore.authorizationStatus(for: .event)
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var workspace: Workspace?

    var isConnected: Bool {
        (workspace?.data.settings.calendarEnabled ?? true) && (status == .fullAccess || !events.isEmpty)
    }

    func start(workspace: Workspace) {
        self.workspace = workspace
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func connect() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = EKEventStore.authorizationStatus(for: .event)
                self.workspace?.data.settings.calendarEnabled = granted
                self.refresh()
                if !granted, self.status == .denied { Self.openPrivacySettings() }
            }
        }
    }

    func disconnect() {
        workspace?.data.settings.calendarEnabled = false
        events = []
    }

    func refresh() {
        let current = EKEventStore.authorizationStatus(for: .event) // it may have changed in System Settings
        if current != status { status = current }
        guard let workspace, workspace.data.settings.calendarEnabled, current == .fullAccess else {
            if workspace != nil { events = [] }
            return
        }
        let cal = workspace.calendar
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let now = Date()
        let rows = store.events(matching: predicate)
            .filter { $0.endDate > now }
            .sorted { $0.compareStartDate(with: $1) == .orderedAscending }
            .map { event in
                EventRow(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                         start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                         location: event.location, calendarName: event.calendar?.title ?? "")
            }
        if rows != events { events = rows }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}
