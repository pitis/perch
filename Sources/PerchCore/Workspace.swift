import Foundation
import Observation

/// All planner state and every rule that changes it. The notch UI, the dashboard, Reminders sync and the
/// MCP server all go through this one object on the main thread, so there's one writer and no merge problem.
@Observable
public final class Workspace {
    public var data: AppData { didSet { onChange?() } }
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var clock: () -> Date = { Date() }
    @ObservationIgnored public var calendar = Calendar.current

    public init(data: AppData = AppData()) {
        self.data = data
    }

    public var now: Date { clock() }
    public var today: String { Day.key(now, calendar: calendar) }

    private func index(_ id: UUID) -> Int? { data.tasks.firstIndex { $0.id == id } }
    public func task(_ id: UUID) -> TaskItem? { data.tasks.first { $0.id == id } }

    // MARK: Lists

    public func open(on day: String?) -> [TaskItem] {
        data.tasks.filter { !$0.isCompleted && $0.day == day }.sorted { $0.order < $1.order }
    }

    public var inbox: [TaskItem] { open(on: nil) }

    public func completed(on day: String) -> [TaskItem] {
        data.tasks
            .filter { $0.completedAt.map { Day.key($0, calendar: calendar) == day } ?? false }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    public var overdue: [TaskItem] {
        let today = self.today
        return data.tasks
            .filter { !$0.isCompleted && ($0.day.map { $0 < today } ?? false) }
            .sorted { ($0.day ?? "", $0.order) < ($1.day ?? "", $1.order) }
    }

    public var projects: [String] {
        Array(Set(data.tasks.compactMap(\.project))).sorted()
    }

    // MARK: Tasks

    /// Adds a task from typed or spoken text. Returns nil when there's no title to add.
    @discardableResult
    public func add(_ text: String, defaultDay: String?) -> TaskItem? {
        let parsed = NLParser.parse(text, now: now, calendar: calendar)
        guard !parsed.title.isEmpty else { return nil }
        var task = TaskItem(title: parsed.title, now: now)
        task.day = parsed.day ?? defaultDay
        task.reminderAt = parsed.reminderAt
        task.deadline = parsed.deadline
        task.priority = parsed.priority
        task.project = parsed.project
        task.repeatRule = parsed.repeatRule
        task.order = nextOrder(in: task.day)
        data.tasks.append(task)
        return task
    }

    /// Applies a second reading of the text a task was added from, for languages the parser doesn't read: Apple's on-device
    /// model rewrites its date in English ("tuesday at 2pm") and gives the title without it. Nothing changes when `when`
    /// holds no date, when the title didn't get shorter (so the date wasn't in the text), or when the task's title or dates
    /// were edited since it was added.
    public func applySchedule(_ id: UUID, title: String, when: String, ifUnchangedSince added: TaskItem) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = NLParser.parse("x " + when, now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        guard parsed.day != nil || parsed.reminderAt != nil || parsed.deadline != nil || parsed.repeatRule != nil,
              !title.isEmpty, title.count < added.title.count,
              let current = task(id), current.title == added.title, current.day == added.day, current.reminderAt == added.reminderAt,
              current.deadline == added.deadline, current.repeatRule == added.repeatRule
        else { return }
        let order = parsed.day.flatMap { $0 == current.day ? nil : nextOrder(in: $0) }
        update(id) { task in
            task.title = title
            if let day = parsed.day { task.day = day }
            if let order { task.order = order }
            task.reminderAt = parsed.reminderAt
            task.deadline = parsed.deadline
            task.repeatRule = parsed.repeatRule
        }
    }

    private func nextOrder(in day: String?) -> Double {
        (open(on: day).map(\.order).max() ?? 0) + 1
    }

    /// Edits a task and records the change time, which Reminders sync uses to pick a winner.
    public func update(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = index(id) else { return }
        var task = data.tasks[i]
        let before = task
        change(&task)
        guard task != before else { return }
        task.modifiedAt = now
        if task.reminderAt != before.reminderAt {
            task.snoozedUntil = nil
            task.reminderFiredAt = nil
        }
        data.tasks[i] = task
    }

    public func setCompleted(_ id: UUID, _ done: Bool) {
        guard let i = index(id), done != data.tasks[i].isCompleted else { return }
        var tasks = data.tasks
        if done {
            tasks[i].completedAt = now
            tasks[i].snoozedUntil = nil
            tasks[i].modifiedAt = now
            if let rule = tasks[i].repeatRule {
                let next = nextInstance(of: tasks[i], rule: rule)
                tasks[i].spawnedNextId = next.id
                tasks.append(next)
            }
        } else {
            tasks[i].completedAt = nil
            tasks[i].modifiedAt = now
            if let spawned = tasks[i].spawnedNextId,
               let j = tasks.firstIndex(where: { $0.id == spawned && !$0.isCompleted }) {
                if let remote = tasks[j].remoteId { data.pendingRemoteDeletes.append(remote) }
                tasks.remove(at: j)
            }
            if let k = tasks.firstIndex(where: { $0.id == id }) { tasks[k].spawnedNextId = nil }
        }
        data.tasks = tasks
    }

    private func nextInstance(of task: TaskItem, rule: RepeatRule) -> TaskItem {
        let nextDay = rule.next(from: task.day ?? today, today: today, calendar: calendar)
        var next = task
        next.id = UUID()
        next.day = nextDay
        next.completedAt = nil
        next.remoteId = nil
        next.spawnedNextId = nil
        next.focusedSeconds = 0
        next.snoozedUntil = nil
        next.reminderFiredAt = nil
        next.createdAt = now
        next.modifiedAt = now
        next.order = nextOrder(in: nextDay)
        next.steps = task.steps.map { var s = $0; s.done = false; return s }
        next.reminderAt = task.reminderAt.map { retime($0, to: nextDay) }
        return next
    }

    private func retime(_ date: Date, to day: String) -> Date {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Day.at(day, hour: c.hour ?? 9, minute: c.minute ?? 0, calendar: calendar)
    }

    /// Moves a task to a day (nil is the Inbox), optionally dropping it just above another task.
    public func move(_ id: UUID, to day: String?, before target: UUID? = nil) {
        guard let i = index(id), !data.tasks[i].isCompleted else { return }
        var task = data.tasks[i]
        if task.day != day {
            task.day = day
            task.reminderAt = day.flatMap { d in task.reminderAt.map { retime($0, to: d) } }
            task.snoozedUntil = nil
            task.reminderFiredAt = nil
            task.modifiedAt = now
        }
        let peers = open(on: day).filter { $0.id != id }
        if let target, let position = peers.firstIndex(where: { $0.id == target }) {
            let above = position > 0 ? peers[position - 1].order : peers[position].order - 1
            task.order = (above + peers[position].order) / 2
        } else {
            task.order = (peers.last?.order ?? 0) + 1
        }
        data.tasks[i] = task
    }

    /// Carries every overdue task forward to today.
    public func carryOverdueToToday() {
        for task in overdue { move(task.id, to: today) }
    }

    public func delete(_ id: UUID) {
        guard let i = index(id) else { return }
        let task = data.tasks[i]
        var next = data
        next.tasks.remove(at: i)
        next.trash.insert(task, at: 0)
        if next.trash.count > 50 { next.trash.removeLast(next.trash.count - 50) }
        if let remote = task.remoteId { next.pendingRemoteDeletes.append(remote) }
        data = next
    }

    public func undoDelete(_ id: UUID) {
        guard let i = data.trash.firstIndex(where: { $0.id == id }) else { return }
        var next = data
        var task = next.trash.remove(at: i)
        if let remote = task.remoteId {
            if let pending = next.pendingRemoteDeletes.firstIndex(of: remote) {
                next.pendingRemoteDeletes.remove(at: pending)
            } else {
                // A sync already removed it from Reminders, so it has to be created again.
                task.remoteId = nil
            }
        }
        next.tasks.append(task)
        data = next
    }

    // MARK: Reminders

    public func snooze(_ id: UUID, minutes: Int = 5) {
        guard let i = index(id) else { return }
        data.tasks[i].snoozedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
        data.tasks[i].reminderFiredAt = nil
    }

    /// Reminders due now, each marked fired so it rings once. Anything over a day stale is retired silently,
    /// so opening the app after a long time away doesn't produce a wall of alerts.
    public func takeDueReminders() -> [TaskItem] {
        let now = self.now
        var due: [TaskItem] = []
        var tasks = data.tasks
        var changed = false
        for i in tasks.indices where !tasks[i].isCompleted {
            guard let at = tasks[i].effectiveReminder, at <= now else { continue }
            if let fired = tasks[i].reminderFiredAt, fired >= at { continue }
            tasks[i].reminderFiredAt = now
            changed = true
            if now.timeIntervalSince(at) < 24 * 3600 { due.append(tasks[i]) }
        }
        if changed { data.tasks = tasks }
        return due.sorted { ($0.effectiveReminder ?? now) < ($1.effectiveReminder ?? now) }
    }

    public var upcomingReminders: [TaskItem] {
        data.tasks.filter { !$0.isCompleted && ($0.effectiveReminder.map { $0 > now } ?? false) }
    }

    /// When something next needs attention: a reminder coming due or a countdown ending.
    public func nextWake() -> Date? {
        let reminders = data.tasks.compactMap { task -> Date? in
            guard !task.isCompleted, let at = task.effectiveReminder else { return nil }
            if let fired = task.reminderFiredAt, fired >= at { return nil }
            return at
        }
        var wake = reminders.min()
        let focus = data.focus
        if focus.phase == .running, focus.mode == .countdown {
            let end = now.addingTimeInterval(focus.remaining(at: now))
            wake = min(wake ?? end, end)
        }
        return wake
    }

    // MARK: Notes

    public func note(on day: String) -> String { data.notes[day] ?? "" }

    public func setNote(_ text: String, on day: String) {
        guard data.notes[day] != text, !(data.notes[day] == nil && text.isEmpty) else { return }
        data.notes[day] = text
    }

    public func appendNote(_ text: String, on day: String) {
        let existing = note(on: day)
        setNote(existing.isEmpty ? text : existing + "\n" + text, on: day)
    }

    /// Turns one Notepad line into a task, ignoring list markers. Returns nil for a blank line.
    @discardableResult
    public func taskFromNoteLine(_ line: String, day: String) -> TaskItem? {
        let cleaned = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^(?:[-*•]\\s+|\\[[ xX]?\\]\\s*|\\d+[.)]\\s+)", with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }
        return add(cleaned, defaultDay: day)
    }

    // MARK: Focus

    /// Starts a new session, logging whatever was running first.
    public func focusStart(taskId: UUID? = nil, minutes: Int? = nil, stopwatch: Bool = false) {
        finishSession()
        var focus = FocusTimer()
        focus.taskId = taskId
        focus.mode = stopwatch ? .stopwatch : .countdown
        let planned = taskId.flatMap { task($0)?.plannedMinutes }
        focus.targetSeconds = max(1, minutes ?? planned ?? data.settings.defaultFocusMinutes) * 60
        focus.phase = .running
        focus.runningSince = now
        data.focus = focus
    }

    private func closeSegment(_ focus: inout FocusTimer) {
        guard let since = focus.runningSince else { return }
        var end = now
        if focus.mode == .countdown {
            // A countdown can't count time after it hit zero, even if the wake-up came late.
            end = min(end, since.addingTimeInterval(focus.remaining(at: since)))
        }
        focus.accumulated += max(0, end.timeIntervalSince(since))
        focus.segments.append(FocusSegment(start: since, end: end))
        focus.runningSince = nil
    }

    /// Also what happens when the Mac sleeps: time asleep is never counted as focus.
    public func focusPause() {
        guard data.focus.phase == .running else { return }
        var focus = data.focus
        closeSegment(&focus)
        focus.phase = .paused
        data.focus = focus
    }

    public func focusResume() {
        guard data.focus.phase == .paused else { return }
        var focus = data.focus
        focus.phase = .running
        focus.runningSince = now
        data.focus = focus
    }

    public func focusAddFive() {
        guard data.focus.mode == .countdown, data.focus.isActive else { return }
        var focus = data.focus
        focus.targetSeconds += 5 * 60
        if focus.phase == .done {
            focus.phase = .running
            focus.runningSince = now
        }
        data.focus = focus
    }

    /// Ends a countdown whose time is up. Returns true when it just finished, so the app can chime.
    @discardableResult
    public func focusTick() -> Bool {
        let focus = data.focus
        guard focus.phase == .running, focus.mode == .countdown, focus.remaining(at: now) <= 0 else { return false }
        logSegments(andSetPhase: .done)
        return true
    }

    public func focusStop() {
        finishSession()
        var focus = FocusTimer()
        focus.targetSeconds = data.focus.targetSeconds
        focus.mode = data.focus.mode
        focus.taskId = data.focus.taskId
        data.focus = focus
    }

    public func focusSetTarget(minutes: Int) {
        guard data.focus.phase == .idle, minutes > 0 else { return }
        data.focus.targetSeconds = minutes * 60
        data.focus.mode = .countdown
    }

    public func focusSetStopwatch() {
        guard data.focus.phase == .idle else { return }
        data.focus.mode = .stopwatch
    }

    public func focusSetTask(_ id: UUID?) {
        data.focus.taskId = id
        if data.focus.phase == .idle, let minutes = id.flatMap({ task($0)?.plannedMinutes }) {
            data.focus.targetSeconds = minutes * 60
        }
    }

    /// On launch: a timer that was running when the app last stopped resumes paused. The unfinished segment is
    /// dropped, because nothing records how much of that gap was real focus.
    public func recoverFocusAfterLaunch() {
        guard data.focus.phase == .running else { return }
        data.focus.runningSince = nil
        data.focus.phase = .paused
    }

    private func finishSession() {
        guard data.focus.isActive else { return }
        logSegments(andSetPhase: data.focus.phase)
    }

    private func logSegments(andSetPhase phase: FocusTimer.Phase) {
        var next = data
        closeSegment(&next.focus)
        next.focus.phase = phase
        let segments = next.focus.segments
        next.focus.segments = []
        if !segments.isEmpty {
            let id = next.focus.taskId
            let session = FocusSession(taskId: id, taskTitle: id.flatMap { task($0)?.title }, segments: segments)
            next.sessions.append(session)
            if let id, let i = next.tasks.firstIndex(where: { $0.id == id }) {
                next.tasks[i].focusedSeconds += Int(session.activeSeconds.rounded())
            }
        }
        data = next
    }

    // MARK: Backup

    public func exportJSON() throws -> Data {
        try Store.encoder.encode(data)
    }
}
