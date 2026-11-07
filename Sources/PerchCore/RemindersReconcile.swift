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

/// An Apple Reminders item, as far as sync cares. EventKit stays out of this file so the decisions can be tested.
public struct RemoteReminder: Equatable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var deadline: String?
    public var due: RemoteDue?
    public var priority: Priority
    public var completed: Bool
    public var modifiedAt: Date

    public init(id: String, title: String, notes: String = "", deadline: String? = nil, due: RemoteDue? = nil,
                priority: Priority = .none, completed: Bool = false, modifiedAt: Date = .distantPast) {
        self.id = id
        self.title = title
        self.notes = notes
        self.deadline = deadline
        self.due = due
        self.priority = priority
        self.completed = completed
        self.modifiedAt = modifiedAt
    }
}

public enum SyncAction: Equatable, Sendable {
    case createRemote(UUID)
    case pushRemote(UUID, remoteId: String)
    case pullLocal(UUID, RemoteReminder)
    case importLocal(RemoteReminder)
    case deleteLocal(UUID)
    case unlink(UUID)
    case deleteRemote(String)
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

    /// Decides what one sync pass should do. On a conflict the most recent edit wins.
    public static func plan(tasks: [TaskItem], remote: [RemoteReminder], pendingDeletes: [String],
                            calendar: Calendar = .current) -> [SyncAction] {
        let byId = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var actions: [SyncAction] = pendingDeletes.filter { byId[$0] != nil }.map { .deleteRemote($0) }

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
                actions.append(massLoss || task.isCompleted ? .unlink(task.id) : .deleteLocal(task.id))
                continue
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
