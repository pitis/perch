import Foundation

/// Days are stored as local "yyyy-MM-dd" strings: a task planned for Friday stays on Friday across time zones,
/// and string order is chronological order.
public enum Day {
    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func isValid(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let m = Int(parts[1]), let d = Int(parts[2]), Int(parts[0]) != nil else { return false }
        return (1...12).contains(m) && (1...31).contains(d)
    }

    public static func date(_ key: String, calendar: Calendar = .current) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return .distantPast }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) ?? .distantPast
    }

    public static func at(_ key: String, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return .distantPast }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: hour, minute: minute)) ?? .distantPast
    }

    public static func adding(_ days: Int, to key: String, calendar: Calendar = .current) -> String {
        Day.key(calendar.date(byAdding: .day, value: days, to: date(key, calendar: calendar))!, calendar: calendar)
    }

    public static func weekday(_ key: String, calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date(key, calendar: calendar))
    }

    /// "Today", "Tomorrow", "Yesterday", or "Thu 12 Nov".
    public static func label(_ key: String, today: String, calendar: Calendar = .current) -> String {
        if key == today { return "Today" }
        if key == adding(1, to: today, calendar: calendar) { return "Tomorrow" }
        if key == adding(-1, to: today, calendar: calendar) { return "Yesterday" }
        return format(key, "EEE d MMM", calendar: calendar)
    }

    public static func format(_ key: String, _ pattern: String, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date(key, calendar: calendar))
    }
}

extension KeyedDecodingContainer {
    /// Missing or malformed fields fall back, so adding a field later can't make an existing store unreadable.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case none = 0, low, medium, high

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "none": self = .none
        case "low": self = .low
        case "medium", "med": self = .medium
        case "high": self = .high
        default: return nil
        }
    }
}

public struct RepeatRule: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case daily, weekdays, weekly, monthly, yearly }

    public var kind: Kind
    public var interval: Int
    /// Calendar weekday numbers (1 = Sunday). Weekly rules only.
    public var weekdays: [Int]?

    public init(kind: Kind, interval: Int = 1, weekdays: [Int]? = nil) {
        self.kind = kind
        self.interval = max(1, interval)
        self.weekdays = weekdays
    }

    public var label: String {
        if kind == .weekly, let weekdays, !weekdays.isEmpty {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ")
        }
        if kind == .weekdays { return "Weekdays" }
        let units: [Kind: (one: String, many: String)] = [
            .daily: ("Daily", "days"), .weekly: ("Weekly", "weeks"),
            .monthly: ("Monthly", "months"), .yearly: ("Yearly", "years"),
        ]
        let unit = units[kind]!
        return interval == 1 ? unit.one : "Every \(interval) \(unit.many)"
    }

    /// The first day on or after `from` that this rule lands on.
    public func first(onOrAfter from: String, calendar: Calendar = .current) -> String {
        var day = from
        for _ in 0..<8 {
            if matches(day, calendar: calendar) { return day }
            day = Day.adding(1, to: day, calendar: calendar)
        }
        return from
    }

    /// Todoist-style: finishing an overdue repeat schedules the next occurrence after both its own day and today.
    public func next(from base: String, today: String, calendar: Calendar = .current) -> String {
        let floor = max(base, today)
        let start = Day.date(base, calendar: calendar)
        var step = 1
        while step < 5000 {
            let candidate: String
            switch kind {
            case .daily:
                candidate = Day.adding(step * interval, to: base, calendar: calendar)
            case .weekdays:
                candidate = Day.adding(step, to: base, calendar: calendar)
            case .weekly:
                let multiplier = (weekdays?.isEmpty ?? true) ? 7 * interval : 1
                candidate = Day.adding(step * multiplier, to: base, calendar: calendar)
            case .monthly, .yearly:
                // Stepping from the original date keeps the 31st from drifting to the 28th forever.
                let unit: Calendar.Component = kind == .monthly ? .month : .year
                candidate = Day.key(calendar.date(byAdding: unit, value: step * interval, to: start)!, calendar: calendar)
            }
            if candidate > floor, matches(candidate, calendar: calendar) { return candidate }
            step += 1
        }
        return Day.adding(1, to: floor, calendar: calendar)
    }

    private func matches(_ day: String, calendar: Calendar) -> Bool {
        let weekday = Day.weekday(day, calendar: calendar)
        switch kind {
        case .weekdays: return (2...6).contains(weekday)
        case .weekly:
            guard let weekdays, !weekdays.isEmpty else { return true }
            return weekdays.contains(weekday)
        default: return true
        }
    }
}

public struct Step: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var done: Bool

    public init(title: String, done: Bool = false) {
        id = UUID()
        self.title = title
        self.done = done
    }
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    /// nil means the Inbox.
    public var day: String?
    public var reminderAt: Date?
    public var snoozedUntil: Date?
    public var reminderFiredAt: Date?
    public var deadline: String?
    public var priority: Priority
    public var project: String?
    public var steps: [Step]
    public var repeatRule: RepeatRule?
    public var plannedMinutes: Int?
    public var focusedSeconds: Int
    public var order: Double
    public var completedAt: Date?
    public var createdAt: Date
    public var modifiedAt: Date
    /// Identifier of the linked item in Apple Reminders.
    public var remoteId: String?
    /// The repeat instance created when this one was completed, so un-completing can take it back.
    public var spawnedNextId: UUID?

    public init(title: String, now: Date = Date()) {
        id = UUID()
        self.title = title
        notes = ""
        priority = .none
        steps = []
        focusedSeconds = 0
        order = 0
        createdAt = now
        modifiedAt = now
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = c.lenient(.notes, "")
        day = c.lenient(.day, nil)
        reminderAt = c.lenient(.reminderAt, nil)
        snoozedUntil = c.lenient(.snoozedUntil, nil)
        reminderFiredAt = c.lenient(.reminderFiredAt, nil)
        deadline = c.lenient(.deadline, nil)
        priority = c.lenient(.priority, .none)
        project = c.lenient(.project, nil)
        steps = c.lenient(.steps, [])
        repeatRule = c.lenient(.repeatRule, nil)
        plannedMinutes = c.lenient(.plannedMinutes, nil)
        focusedSeconds = c.lenient(.focusedSeconds, 0)
        order = c.lenient(.order, 0)
        completedAt = c.lenient(.completedAt, nil)
        createdAt = c.lenient(.createdAt, Date())
        modifiedAt = c.lenient(.modifiedAt, Date())
        remoteId = c.lenient(.remoteId, nil)
        spawnedNextId = c.lenient(.spawnedNextId, nil)
    }

    public var isCompleted: Bool { completedAt != nil }
    public var effectiveReminder: Date? { snoozedUntil ?? reminderAt }
}

public struct FocusSegment: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public struct FocusSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var taskId: UUID?
    public var taskTitle: String?
    public var segments: [FocusSegment]

    public init(taskId: UUID?, taskTitle: String?, segments: [FocusSegment]) {
        id = UUID()
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.segments = segments
    }

    public var activeSeconds: TimeInterval { segments.reduce(0) { $0 + $1.seconds } }
}

public struct FocusTimer: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, running, paused, done }
    public enum Mode: String, Codable, Sendable { case countdown, stopwatch }

    public var phase: Phase = .idle
    public var mode: Mode = .countdown
    public var targetSeconds: Int = 25 * 60
    public var taskId: UUID?
    public var runningSince: Date?
    /// Active time from segments that have already ended.
    public var accumulated: TimeInterval = 0
    /// Segments not yet logged to a session.
    public var segments: [FocusSegment] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = c.lenient(.phase, .idle)
        mode = c.lenient(.mode, .countdown)
        targetSeconds = c.lenient(.targetSeconds, 25 * 60)
        taskId = c.lenient(.taskId, nil)
        runningSince = c.lenient(.runningSince, nil)
        accumulated = c.lenient(.accumulated, 0)
        segments = c.lenient(.segments, [])
    }

    public func elapsed(at now: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, TimeInterval(targetSeconds) - elapsed(at: now))
    }

    /// Seconds on the clock face: counts down for a countdown, up for a stopwatch.
    public func display(at now: Date) -> TimeInterval {
        mode == .countdown ? remaining(at: now) : elapsed(at: now)
    }

    public func progress(at now: Date) -> Double {
        guard mode == .countdown, targetSeconds > 0 else { return 0 }
        return min(1, elapsed(at: now) / Double(targetSeconds))
    }

    public var isActive: Bool { phase != .idle }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

public struct CardConfig: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case focus, tasks, notes, agenda

        public var title: String {
            switch self {
            case .focus: "Focus"
            case .tasks: "Tasks"
            case .notes: "Notepad"
            case .agenda: "Events"
            }
        }

        /// Points below which the card's controls start to clip or wrap, so dragging stops there.
        public var minWidth: Double {
            switch self {
            case .focus: 150
            case .tasks: 270 // the tabs and the day picker wrap below this
            case .notes: 140
            case .agenda: 140
            }
        }
    }

    /// The S, M and L presets in Customize. Dragging the gap between cards sets any weight in between.
    public enum Width: String, Codable, CaseIterable, Sendable {
        case narrow, regular, wide

        public var weight: Double {
            switch self {
            case .narrow: 0.85
            case .regular: 1
            case .wide: 1.9
            }
        }
    }

    public var kind: Kind
    public var visible: Bool
    /// The card's share of the row, relative to the other visible cards.
    public var weight: Double
    public var id: Kind { kind }

    public init(kind: Kind, visible: Bool = true, width: Width = .regular) {
        self.kind = kind
        self.visible = visible
        self.weight = width.weight
    }

    private enum OlderKeys: String, CodingKey { case width }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        visible = c.lenient(.visible, true)
        // Files from before drag-to-resize store a preset instead of a weight.
        let older = try decoder.container(keyedBy: OlderKeys.self)
        weight = c.lenient(.weight, older.lenient(.width, Width.regular).weight)
    }
}

public enum ClockStyle: String, Codable, CaseIterable, Sendable {
    case dots, mono, rounded

    public var label: String {
        switch self {
        case .dots: "Dot matrix"
        case .mono: "Mono"
        case .rounded: "Rounded"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// nil follows the pointer between screens; otherwise the localized name of the screen to stay on.
    public var showOnScreen: String?
    public var notchOnMonitors = true
    public var chime = true
    public var remindersSync = false
    public var reminderListId: String?
    public var calendarEnabled = false
    public var captureCopied = true
    /// Off until asked for: watching the screenshot folder is what makes macOS prompt for Desktop access.
    public var captureScreenshots = false
    public var autoClassify = true
    public var blackAndWhite = false
    public var clockStyle = ClockStyle.dots
    public var defaultFocusMinutes = 25
    public var cards: [CardConfig] = [
        CardConfig(kind: .tasks, width: .wide),
        CardConfig(kind: .focus, width: .regular),
        CardConfig(kind: .notes, width: .regular),
        CardConfig(kind: .agenda, width: .regular),
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        showOnScreen = c.lenient(.showOnScreen, nil)
        notchOnMonitors = c.lenient(.notchOnMonitors, d.notchOnMonitors)
        chime = c.lenient(.chime, d.chime)
        remindersSync = c.lenient(.remindersSync, d.remindersSync)
        reminderListId = c.lenient(.reminderListId, nil)
        calendarEnabled = c.lenient(.calendarEnabled, d.calendarEnabled)
        captureCopied = c.lenient(.captureCopied, d.captureCopied)
        captureScreenshots = c.lenient(.captureScreenshots, d.captureScreenshots)
        autoClassify = c.lenient(.autoClassify, d.autoClassify)
        blackAndWhite = c.lenient(.blackAndWhite, d.blackAndWhite)
        clockStyle = c.lenient(.clockStyle, d.clockStyle)
        defaultFocusMinutes = c.lenient(.defaultFocusMinutes, d.defaultFocusMinutes)
        cards = c.lenient(.cards, d.cards)
    }
}

/// Everything in the planner backup. Clips live in their own file so clipboard contents never end up in an export.
public struct AppData: Codable, Equatable, Sendable {
    public var tasks: [TaskItem] = []
    /// Recently deleted tasks, newest first, so a delete can be undone.
    public var trash: [TaskItem] = []
    /// Reminders items to remove on the next sync, after their task was deleted here.
    public var pendingRemoteDeletes: [String] = []
    /// Notepad text by day.
    public var notes: [String: String] = [:]
    /// Events ticked off in the Events card, as "eventId@day". Local only: Calendar itself is never written to.
    public var checkedEvents: [String] = []
    public var sessions: [FocusSession] = []
    public var focus = FocusTimer()
    public var settings = AppSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        trash = c.lenient(.trash, [])
        pendingRemoteDeletes = c.lenient(.pendingRemoteDeletes, [])
        notes = c.lenient(.notes, [:])
        checkedEvents = c.lenient(.checkedEvents, [])
        sessions = c.lenient(.sessions, [])
        focus = c.lenient(.focus, FocusTimer())
        settings = c.lenient(.settings, AppSettings())
    }
}
