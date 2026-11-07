import Foundation

public struct DayStat: Equatable, Sendable {
    public var day: String
    public var completed: Int
    public var planned: Int
    public var focusSeconds: Int
}

public struct InsightsSummary: Equatable, Sendable {
    public var headline: String
    public var sentence: String
    public var completed: Int
    public var previousCompleted: Int
    public var planned: Int
    public var focusSeconds: Int
    public var activeDays: Int
    /// The last seven days, oldest first.
    public var days: [DayStat]
    /// Active focus seconds per hour of the day over the last seven days.
    public var hourly: [Int]
    /// The busiest hour, such as 9 for 9–10 AM. nil when there's no focus time yet.
    public var peakHour: Int?

    public static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}

extension Workspace {
    public func insights() -> InsightsSummary {
        let today = self.today
        let window = (0..<7).map { Day.adding($0 - 6, to: today, calendar: calendar) }
        let previous = Set((0..<7).map { Day.adding($0 - 13, to: today, calendar: calendar) })

        var completedByDay: [String: Int] = [:]
        var plannedByDay: [String: Int] = [:]
        for task in data.tasks {
            if let at = task.completedAt { completedByDay[Day.key(at, calendar: calendar), default: 0] += 1 }
            if let day = task.day { plannedByDay[day, default: 0] += 1 }
        }

        var focusByDay: [String: TimeInterval] = [:]
        var hourly = [TimeInterval](repeating: 0, count: 24)
        let windowSet = Set(window)
        for segment in data.sessions.flatMap(\.segments) {
            // Split at hour boundaries so a 9:50–10:20 session counts towards both hours and, if needed, both days.
            var cursor = segment.start
            while cursor < segment.end {
                let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.end ?? segment.end
                let end = min(hourStart, segment.end)
                let key = Day.key(cursor, calendar: calendar)
                focusByDay[key, default: 0] += end.timeIntervalSince(cursor)
                if windowSet.contains(key) {
                    hourly[calendar.component(.hour, from: cursor)] += end.timeIntervalSince(cursor)
                }
                cursor = end
            }
        }

        let days = window.map { day -> DayStat in
            let done = completedByDay[day] ?? 0
            return DayStat(
                day: day,
                completed: done,
                planned: max(plannedByDay[day] ?? 0, done),
                focusSeconds: Int((focusByDay[day] ?? 0).rounded())
            )
        }

        let completed = days.reduce(0) { $0 + $1.completed }
        let planned = days.reduce(0) { $0 + $1.planned }
        let focus = days.reduce(0) { $0 + $1.focusSeconds }
        let earlier = previous.reduce(0) { $0 + (completedByDay[$1] ?? 0) }
        let active = days.filter { $0.completed > 0 || $0.focusSeconds > 0 }.count

        let headline: String
        if completed == 0, focus == 0 {
            headline = "A fresh start"
        } else if completed > earlier {
            headline = "Momentum is building"
        } else if completed == earlier {
            headline = "Holding steady"
        } else {
            headline = "A quieter week"
        }

        let tasksWord = completed == 1 ? "task" : "tasks"
        var sentence = "\(completed) \(tasksWord) done"
        if earlier != completed, earlier > 0 {
            sentence += ", \(completed > earlier ? "up" : "down") from \(earlier) the week before"
        }
        sentence += ", with \(InsightsSummary.duration(focus)) focused."

        let hourlyInts = hourly.map { Int($0.rounded()) }
        let peakValue = hourlyInts.max() ?? 0
        return InsightsSummary(
            headline: headline,
            sentence: sentence,
            completed: completed,
            previousCompleted: earlier,
            planned: planned,
            focusSeconds: focus,
            activeDays: active,
            days: days,
            hourly: hourlyInts,
            peakHour: peakValue > 0 ? hourlyInts.firstIndex(of: peakValue) : nil
        )
    }
}
