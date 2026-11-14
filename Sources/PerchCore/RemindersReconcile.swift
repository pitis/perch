import Foundation

public struct RemoteDue: Equatable, Sendable {
    public var day: String
    /// nil for an all-day item.
    public var time: Date?

    public init(day: String, time: Date? = nil) {
        self.day = day
        self.time = time
    }
}

/// A repeat rule set in the Reminders app. EventKit stays in `RemindersSync`. When `unsupported`, the other fields don't matter.
public struct RemoteRecurrence: Equatable, Sendable {
    public enum Frequency: Sendable { case daily, weekly, monthly, yearly }

    public var frequency: Frequency
    public var interval: Int
    /// Calendar weekday numbers (1 = Sunday) the rule picks, if any.
    public var weekdays: [Int]
    /// Perch's repeats can't say this rule: it ends, is one of several, has an unknown frequency, or pins months, days of
    /// the month or year, weeks of the year, positions, or an nth weekday like "first Monday".
    public var unsupported: Bool

    public init(frequency: Frequency, interval: Int, weekdays: [Int] = [], unsupported: Bool = false) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.unsupported = unsupported
    }

    /// The same repeat in Perch's terms, or nil when Perch can't express it. `dueWeekday` is the reminder's own weekday.
    public func repeatRule(dueWeekday: Int? = nil) -> RepeatRule? {
        var days = Array(Set(weekdays)).sorted()
        // Weekly on its own day is a plain weekly repeat, which can also skip weeks.
        if frequency == .weekly, let dueWeekday, days == [dueWeekday] { days = [] }
        guard !unsupported, interval >= 1, days.allSatisfy((1...7).contains) else { return nil }
        guard !days.isEmpty else {
            let kind: RepeatRule.Kind = switch frequency {
            case .daily: .daily
            case .weekly: .weekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
            return RepeatRule(kind: kind, interval: interval)
        }
        // Perch's chosen days only work on a weekly repeat that runs every week, so other frequencies with days, or
        // "every 2 weeks on Monday and Thursday", have no equivalent.
        guard frequency == .weekly, interval == 1 else { return nil }
        return days == [2, 3, 4, 5, 6] ? RepeatRule(kind: .weekdays) : RepeatRule(kind: .weekly, weekdays: days)
    }
}

/// An Apple Reminders item, as far as sync cares. EventKit stays out of this file so the decisions can be tested.
public struct RemoteReminder: Equatable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var deadline: String?
    public var due: RemoteDue?
    public var priority: Priority
    public var completed: Bool
    public var recurrence: RemoteRecurrence?
    public var modifiedAt: Date

    public init(id: String, title: String, notes: String = "", deadline: String? = nil, due: RemoteDue? = nil,
                priority: Priority = .none, completed: Bool = false, recurrence: RemoteRecurrence? = nil,
                modifiedAt: Date = .distantPast) {
        self.id = id
        self.title = title
        self.notes = notes
        self.deadline = deadline
        self.due = due
        self.priority = priority
        self.completed = completed
        self.recurrence = recurrence
        self.modifiedAt = modifiedAt
    }

    func repeatRule(calendar: Calendar) -> RepeatRule? {
        recurrence?.repeatRule(dueWeekday: due.map { Day.weekday($0.day, calendar: calendar) })
    }
}

/// A reminder's alarm, as far as a push from Perch cares. EventKit stays in `RemindersSync`.
public enum RemoteAlarm: Equatable, Sendable {
    /// At a fixed time. Perch treats every one as its own.
    case atTime
    /// Seconds from the due time, like an early reminder set on iPhone. Negative is before. One at 0 rings at the task's
    /// time, so Perch treats it as its own.
    case relative(TimeInterval)
    /// "When I arrive" and the like.
    case location
}

public enum SyncAction: Equatable, Sendable {
    case createRemote(UUID)
    case pushRemote(UUID, remoteId: String)
    case pullLocal(UUID, RemoteReminder)
    case importLocal(RemoteReminder)
    case deleteLocal(UUID)
    case unlink(UUID)
    case deleteRemote(String)
    /// A queued delete whose reminder is no longer in the Perch list (deleted on iPhone, moved to another list, or the
    /// list hasn't finished loading). It's forgotten rather than retried.
    case dropPendingDelete(String)
    /// Takes the repeat rule off a reminder whose repeat Perch now owns, so Reminders can't also make the next one.
    case stripRecurrence(String)
    /// Sets the task's repeat from Reminders, or clears it (nil) when Reminders keeps a rule Perch can't express.
    case adoptRepeat(UUID, RepeatRule?)
}

public enum DeadlineLine {
    private static let prefix = "Deadline: "

    /// Reminders has no deadline field, so a deadline travels as the last line of the notes, readable on iPhone.
    public static func compose(notes: String, deadline: String?) -> String {
        guard let deadline else { return notes }
        return notes.isEmpty ? prefix + deadline : notes + "\n" + prefix + deadline
    }

    public static func split(_ text: String) -> (notes: String, deadline: String?) {
        var lines = text.components(separatedBy: "\n")
        guard let last = lines.last, last.hasPrefix(prefix) else { return (text, nil) }
        let value = String(last.dropFirst(prefix.count))
        guard Day.isValid(value) else { return (text, nil) }
        lines.removeLast()
        return (lines.joined(separator: "\n"), value)
    }
}

public enum Reconciler {
    public static func due(of task: TaskItem, calendar: Calendar = .current) -> RemoteDue? {
        if let at = task.reminderAt { return RemoteDue(day: Day.key(at, calendar: calendar), time: at) }
        return task.day.map { RemoteDue(day: $0) }
    }

    /// Which of a reminder's alarms a push keeps (one per alarm in `current`), and the time of Perch's own alarm to add, if
    /// any. An alarm at a fixed time or at the due time is Perch's, so it's replaced and never rings twice. A location alarm
    /// stays, and so does an early reminder while the task has a time: without one, Perch's task doesn't ring, so neither
    /// should the reminder.
    public static func alarms(_ current: [RemoteAlarm], for task: TaskItem) -> (keep: [Bool], add: Date?) {
        let timed = task.reminderAt != nil
        let keep = current.map { alarm in
            switch alarm {
            case .atTime: false
            case .relative(let offset): timed && offset != 0
            case .location: true
            }
        }
        return (keep, task.reminderAt)
    }

    static func sameContent(_ task: TaskItem, _ remote: RemoteReminder, calendar: Calendar) -> Bool {
        task.title == remote.title
            && task.notes == remote.notes
            && task.deadline == remote.deadline
            && task.priority == remote.priority
            && task.isCompleted == remote.completed
            && sameDue(due(of: task, calendar: calendar), remote.due)
    }

    private static func sameDue(_ a: RemoteDue?, _ b: RemoteDue?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a.day == b.day else { return false }
        switch (a.time, b.time) {
        case (nil, nil): return true
        case let (x?, y?): return Int(x.timeIntervalSince1970 / 60) == Int(y.timeIntervalSince1970 / 60)
        default: return false
        }
    }

    /// Decides what one sync pass should do. On a conflict the most recent edit wins, except that a repeat rule in
    /// Reminders always does. `afterRestore` is `AppData.restoredSinceSync`.
    public static func plan(tasks: [TaskItem], remote: [RemoteReminder], pendingDeletes: [String], afterRestore: Bool,
                            calendar: Calendar = .current) -> [SyncAction] {
        let byId = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A queued delete missing from the fetch is forgotten even if the list only looks empty for now: if it comes back,
        // it comes back as a task. Keeping it would hold the id forever when the reminder is really gone.
        var actions: [SyncAction] = pendingDeletes.map { byId[$0] != nil ? .deleteRemote($0) : .dropPendingDelete($0) }

        let linked = tasks.filter { $0.remoteId != nil }
        let missing = linked.filter { byId[$0.remoteId!] == nil }
        // Many items vanishing at once means the account or list went away, not that you deleted them all.
        // Keep the tasks and relink them instead of wiping the planner.
        let massLoss = missing.count >= 3 && missing.count * 2 >= linked.count

        for task in tasks {
            guard let remoteId = task.remoteId else {
                if !task.isCompleted { actions.append(.createRemote(task.id)) }
                continue
            }
            guard let item = byId[remoteId] else {
                // Right after a restore, the link may be out of date or this Mac never synced. Unlinking makes the reminder
                // again on the next pass.
                actions.append(massLoss || afterRestore || task.isCompleted ? .unlink(task.id) : .deleteLocal(task.id))
                continue
            }
            // Perch makes each occurrence itself, so a rule set in Reminders moves here and comes off the reminder. One Perch
            // can't express stays in Reminders and drops the task's own repeat, so nothing comes twice.
            if item.recurrence != nil {
                let rule = item.repeatRule(calendar: calendar)
                if rule != nil { actions.append(.stripRecurrence(remoteId)) }
                if task.repeatRule != rule { actions.append(.adoptRepeat(task.id, rule)) }
            }
            if sameContent(task, item, calendar: calendar) {
                // Finished on both sides: nothing left to keep in step.
                if task.isCompleted { actions.append(.unlink(task.id)) }
            } else if item.modifiedAt > task.modifiedAt {
                actions.append(.pullLocal(task.id, item))
            } else {
                actions.append(.pushRemote(task.id, remoteId: remoteId))
            }
        }

        let known = Set(linked.map { $0.remoteId! }).union(pendingDeletes)
        for item in remote where !item.completed && !known.contains(item.id) {
            actions.append(.importLocal(item))
            if item.repeatRule(calendar: calendar) != nil { actions.append(.stripRecurrence(item.id)) }
        }
        return actions
    }
}

extension Workspace {
    /// Applies an incoming Reminders change. A date with no time clears the reminder; no date means the Inbox.
    public func applyRemote(_ item: RemoteReminder, to id: UUID) {
        guard var task = task(id) else { return }
        task.title = item.title
        task.notes = item.notes
        task.deadline = item.deadline
        task.priority = item.priority
        let newDay = item.due?.day
        if task.day != newDay { task.order = (open(on: newDay).map(\.order).max() ?? 0) + 1 }
        task.day = newDay
        if task.reminderAt != item.due?.time {
            task.reminderAt = item.due?.time
            task.snoozedUntil = nil
            task.reminderFiredAt = nil
        }
        task.modifiedAt = item.modifiedAt
        if let i = data.tasks.firstIndex(where: { $0.id == id }) { data.tasks[i] = task }
        if item.completed != task.isCompleted { setCompleted(id, item.completed) }
        // Completing just stamped the local clock; keep the remote time so this pass doesn't look like a new local edit.
        if let i = data.tasks.firstIndex(where: { $0.id == id }) { data.tasks[i].modifiedAt = item.modifiedAt }
    }

    public func importRemote(_ item: RemoteReminder) {
        var task = TaskItem(title: item.title.isEmpty ? "Untitled" : item.title, now: now)
        task.notes = item.notes
        task.deadline = item.deadline
        task.priority = item.priority
        task.day = item.due?.day
        task.reminderAt = item.due?.time
        // A reminder already in the past shouldn't ring again here just because it arrived now.
        if let at = task.reminderAt, at <= now { task.reminderFiredAt = now }
        task.repeatRule = item.repeatRule(calendar: calendar)
        task.remoteId = item.id
        task.modifiedAt = item.modifiedAt
        task.order = (open(on: task.day).map(\.order).max() ?? 0) + 1
        data.tasks.append(task)
    }

    /// Deletes a task that was removed in Reminders. It goes to the trash, without queuing a remote delete.
    public func deleteFromRemote(_ id: UUID) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        var next = data
        var task = next.tasks.remove(at: i)
        task.remoteId = nil
        next.trash.insert(task, at: 0)
        if next.trash.count > 50 { next.trash.removeLast(next.trash.count - 50) }
        data = next
    }

    public func setRemoteId(_ remoteId: String?, for id: UUID) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }), data.tasks[i].remoteId != remoteId else { return }
        data.tasks[i].remoteId = remoteId
    }

    /// Sets the task's repeat from Reminders, or clears it (nil) when Reminders keeps a rule Perch can't express. Like
    /// `setRemoteId`, it isn't a local edit, so the change time stays.
    public func setRemoteRepeat(_ rule: RepeatRule?, for id: UUID) {
        guard let i = data.tasks.firstIndex(where: { $0.id == id }), data.tasks[i].repeatRule != rule else { return }
        var tasks = data.tasks
        tasks[i].repeatRule = rule
        // Finished here before the rule arrived, and the rule comes off the reminder: make the next one now.
        if let rule, tasks[i].isCompleted, tasks[i].spawnedNextId == nil {
            let next = nextInstance(of: tasks[i], rule: rule)
            tasks[i].spawnedNextId = next.id
            tasks.append(next)
        }
        data.tasks = tasks
    }

    public func clearPendingRemoteDeletes(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        data.pendingRemoteDeletes.removeAll { ids.contains($0) }
    }

    /// Forgets all links, used when the Reminders list itself is gone. Open tasks are pushed again on the next pass.
    public func unlinkAllRemote() {
        var next = data
        for i in next.tasks.indices { next.tasks[i].remoteId = nil }
        next.pendingRemoteDeletes = []
        data = next
    }
}
