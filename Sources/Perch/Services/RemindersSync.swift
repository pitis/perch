import AppKit
import EventKit
import Observation
import PerchCore

/// Applies the decisions from `Reconciler` to Apple Reminders. iCloud carries the list to iPhone and Apple Watch.
///
/// Repeats live on the Perch side: each occurrence is its own reminder with no recurrence rule. A rule added in the
/// Reminders app becomes the task's repeat and comes off the reminder. One Perch can't express stays there, and the
/// task's own repeat is dropped, so nothing comes twice. Moving the task to the Inbox takes that rule off too.
@Observable
final class RemindersSync {
    private static let listName = "Perch"

    var statusText = ""
    var lastSync: Date?
    var isSyncing = false

    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var work: DispatchWorkItem?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var periodic: Timer?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    private var enabled: Bool { workspace.data.settings.remindersSync }

    func start() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.schedule(after: 1)
        }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.schedule(after: 0) }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        periodic = timer
        if enabled { schedule(after: 0) }
    }

    func setEnabled(_ on: Bool) {
        guard on else {
            workspace.data.settings.remindersSync = false
            statusText = ""
            return
        }
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.workspace.data.settings.remindersSync = granted
                if granted {
                    self.syncNow()
                } else {
                    self.statusText = "Perch doesn't have access to Reminders. Allow it in System Settings › Privacy & Security › Reminders."
                }
            }
        }
    }

    func schedule(after delay: TimeInterval = 2) {
        guard enabled else { return }
        work?.cancel()
        let next = DispatchWorkItem { [weak self] in self?.syncNow() }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
    }

    func syncNow() {
        guard enabled else { return }
        guard !isSyncing else {
            again = true
            return
        }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            statusText = "Perch doesn't have access to Reminders. Allow it in System Settings › Privacy & Security › Reminders."
            return
        }
        isSyncing = true
        do {
            let list = try findOrCreateList()
            store.fetchReminders(matching: store.predicateForReminders(in: [list])) { [weak self] reminders in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // nil means the fetch failed. Empty and failed must never look alike, or every task would seem deleted.
                    if let reminders {
                        self.apply(reminders: reminders, list: list)
                    } else {
                        self.statusText = "Couldn't read the Perch list from Reminders."
                    }
                    self.finish()
                }
            }
        } catch {
            statusText = "Sync failed: \(error.localizedDescription)"
            finish()
        }
    }

    private func finish() {
        isSyncing = false
        if again {
            again = false
            schedule(after: 0.5)
        }
    }

    private func findOrCreateList() throws -> EKCalendar {
        let settings = workspace.data.settings
        if let id = settings.reminderListId, let list = store.calendar(withIdentifier: id) { return list }
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) {
            workspace.data.settings.reminderListId = existing.calendarIdentifier
            return existing
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw NSError(domain: "Perch", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Reminders account found."])
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        // The list we knew about is gone. Forget the links so its absence doesn't read as "you deleted all of these".
        // Only now that the new list exists, so a failure above keeps them.
        if settings.reminderListId != nil { workspace.unlinkAllRemote() }
        workspace.data.settings.reminderListId = list.calendarIdentifier
        return list
    }

    private func apply(reminders: [EKReminder], list: EKCalendar) {
        let byId = Dictionary(reminders.map { (identifier(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let remote = reminders.map(snapshot)
        let afterRestore = workspace.data.restoredSinceSync
        let actions = Reconciler.plan(tasks: workspace.data.tasks, remote: remote, pendingDeletes: workspace.data.pendingRemoteDeletes,
                                      afterRestore: afterRestore, calendar: workspace.calendar)
        var created: [(UUID, EKReminder)] = []
        var finishedDeletes: [String] = []
        var current: SyncAction? // the write EventKit refused, if it refuses one
        do {
            for action in actions {
                current = action
                switch action {
                case .createRemote(let id):
                    guard let task = workspace.task(id) else { continue }
                    let reminder = EKReminder(eventStore: store)
                    reminder.calendar = list
                    write(task, to: reminder)
                    try store.save(reminder, commit: false)
                    created.append((id, reminder))
                case .pushRemote(let id, let remoteId):
                    guard let task = workspace.task(id), let reminder = byId[remoteId] else { continue }
                    write(task, to: reminder)
                    try store.save(reminder, commit: false)
                case .deleteRemote(let remoteId):
                    guard let reminder = byId[remoteId] else { continue }
                    try store.remove(reminder, commit: false)
                    finishedDeletes.append(remoteId)
                case .dropPendingDelete(let remoteId):
                    finishedDeletes.append(remoteId) // cleared with the deletes, so only once the commit succeeds
                case .stripRecurrence(let remoteId):
                    guard let reminder = byId[remoteId] else { continue }
                    reminder.recurrenceRules = nil
                    try store.save(reminder, commit: false)
                case .pullLocal, .importLocal, .deleteLocal, .unlink, .adoptRepeat:
                    break
                }
            }
            current = nil
            try store.commit()
        } catch {
            // Local changes below wait for the next pass, so a failed write can't leave the two sides half-applied.
            store.reset()
            // The same write fails on every pass, so say which reminder it is.
            let name: String? = switch current {
            case .createRemote(let id), .pushRemote(let id, _): workspace.task(id)?.title
            case .deleteRemote(let remoteId), .stripRecurrence(let remoteId): byId[remoteId]?.title
            default: nil
            }
            NSLog("Perch: Reminders sync failed at %@: %@", String(describing: current), String(describing: error))
            statusText = "Sync failed" + (name.map { " on “\($0)”" } ?? "") + ": \(error.localizedDescription)"
            return
        }

        for (id, reminder) in created { workspace.setRemoteId(identifier(of: reminder), for: id) }
        workspace.clearPendingRemoteDeletes(finishedDeletes)
        if afterRestore { workspace.data.restoredSinceSync = false } // the actions below unlink any reminder that's missing

        for action in actions {
            switch action {
            case .pullLocal(let id, let item): workspace.applyRemote(item, to: id)
            case .importLocal(let item): workspace.importRemote(item)
            case .deleteLocal(let id): workspace.deleteFromRemote(id)
            case .unlink(let id): workspace.setRemoteId(nil, for: id)
            case .adoptRepeat(let id, let rule): workspace.setRemoteRepeat(rule, for: id)
            case .createRemote, .pushRemote, .deleteRemote, .dropPendingDelete, .stripRecurrence: break
            }
        }
        lastSync = Date()
        statusText = ""
    }

    private func identifier(of reminder: EKReminder) -> String {
        reminder.calendarItemExternalIdentifier ?? reminder.calendarItemIdentifier
    }

    private func snapshot(_ reminder: EKReminder) -> RemoteReminder {
        let (notes, deadline) = DeadlineLine.split(reminder.notes ?? "")
        var due: RemoteDue?
        if var parts = reminder.dueDateComponents {
            parts.calendar = parts.calendar ?? workspace.calendar
            if let date = parts.date {
                due = RemoteDue(day: Day.key(date, calendar: workspace.calendar), time: parts.hour != nil ? date : nil)
            }
        }
        let priority: Priority
        switch reminder.priority {
        case 1...4: priority = .high
        case 5: priority = .medium
        case 6...9: priority = .low
        default: priority = .none
        }
        return RemoteReminder(id: identifier(of: reminder), title: reminder.title ?? "", notes: notes, deadline: deadline, due: due,
                              priority: priority, completed: reminder.isCompleted, recurrence: recurrence(of: reminder),
                              modifiedAt: reminder.lastModifiedDate ?? .distantPast)
    }

    private func recurrence(of reminder: EKReminder) -> RemoteRecurrence? {
        guard let rules = reminder.recurrenceRules, let rule = rules.first else { return nil }
        let frequency: RemoteRecurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return RemoteRecurrence(frequency: .daily, interval: 1, unsupported: true)
        }
        let days = rule.daysOfTheWeek ?? []
        let pinned = [rule.daysOfTheMonth, rule.daysOfTheYear, rule.weeksOfTheYear, rule.monthsOfTheYear, rule.setPositions]
            .contains { !($0?.isEmpty ?? true) }
        return RemoteRecurrence(frequency: frequency, interval: rule.interval, weekdays: days.map { $0.dayOfTheWeek.rawValue },
                                unsupported: rules.count > 1 || rule.recurrenceEnd != nil || pinned || days.contains { $0.weekNumber != 0 })
    }

    private func write(_ task: TaskItem, to reminder: EKReminder) {
        reminder.title = task.title
        let notes = DeadlineLine.compose(notes: task.notes, deadline: task.deadline)
        reminder.notes = notes.isEmpty ? nil : notes
        switch task.priority {
        case .high: reminder.priority = 1
        case .medium: reminder.priority = 5
        case .low: reminder.priority = 9
        case .none: reminder.priority = 0
        }
        reminder.isCompleted = task.isCompleted

        let cal = workspace.calendar
        if let at = task.reminderAt {
            reminder.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            // The alarm is what makes it ring on iPhone and Apple Watch.
            reminder.alarms = [EKAlarm(absoluteDate: at)]
        } else if let day = task.day {
            reminder.dueDateComponents = cal.dateComponents([.year, .month, .day], from: Day.date(day, calendar: cal))
            reminder.alarms = nil
        } else {
            reminder.dueDateComponents = nil
            reminder.alarms = nil
            // EventKit refuses a repeating reminder with no date, and that would fail every pass from then on.
            reminder.recurrenceRules = nil
        }
    }
}
